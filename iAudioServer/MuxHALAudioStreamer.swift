//
//  AudioStreamer.swift
//  iAudioServer
//
//  Created by Travis Ziegler on 12/19/20.
//

import Foundation
import AVFoundation
import CoreAudio
import AudioUnit
import AudioToolbox

let kAudioInputBus : UInt32 = 1;    // input bus element on AUHAL
let kAudioOutputBus : UInt32 = 0;   // output bus element on the AUHAL

/// Class in charge of streaming audio from the HAL plugin USBAudioDriver.
///
/// Uses AUHAL to communicate with the virtual device and issues resulting
/// data to callbacks passed into [makeSession](x-source-tag://makeSession)
class MuxHALAudioStreamer {
    
    var micAuhal: AUHALAudioPlayer!
    var usbAuhal: AUHALAudioRecorder!
    
    /// Callback when new PCM Audio data packet has been rendered.
    var packetReady: ((UnsafeMutableRawPointer, Int) -> Void)!
    
    /// Audio stream format we will send over usb to the device.
    var usbAF: AudioStreamBasicDescription!
    
    /// Audio stream format we will receive from the device.
    var micAF: AudioStreamBasicDescription!
    
    /// The AUHAL Audio Unit responseible for polling system audio.
    var usbAU: AudioComponentInstance!
    
    /// The AUHAL Audio Unit responseible for piping mic data from iOS.
    var micAU: AudioComponentInstance!

    let TAG = "MuxHALAudioStreamer"
    
    var useMic = true
    
    var usbDriverDeviceID : AudioDeviceID!
    var micDriverDeviceID : AudioDeviceID? = nil

    /// Stops and disposes current AUHAL unit.
    func endSession() {
        AudioOutputUnitStop(usbAU)
        AudioComponentInstanceDispose(usbAU)
        if useMic {
            AudioOutputUnitStop(micAU)
            AudioComponentInstanceDispose(micAU)
        }
    }
    
    /// Serializes AudioStreamBasicDescription to Data for socket transmission
    func asbdToData(asbd : AudioStreamBasicDescription) -> Data {
        return withUnsafeBytes(of: asbd) {
            return Data(bytes: ($0.baseAddress)!,
                        count: MemoryLayout.size(ofValue: asbd))
        }
    }
    
    func instantiateAUHAL(au : UnsafeMutablePointer<AudioComponentInstance?>) {
        // Find HAL audio component.
        var desc = AudioComponentDescription(
                    componentType:          kAudioUnitType_Output,
                    componentSubType:       kAudioUnitSubType_HALOutput,
                    componentManufacturer:  0,
                    componentFlags:         0,
                    componentFlagsMask:     0)

        let count = AudioComponentCount(&desc)
        if count == 0 {
            Logger.log(.emergency, TAG, "Failed to find AUHAL audio unit!")
            return
        }
    
        // Instantiate AUHAL audio unit.
        let comp = AudioComponentFindNext(nil, &desc)
        AudioComponentInstanceNew(comp!, au)
    }
    
    /// Sets up our USBAudioDriver to poll for new audio input (which is the
    /// system's audio output). Then sends the resuliting PCM audio data to
    /// the packet ready callback.
    /// - Parameters:
    ///   - _packetReady: Called when a new buffer of audio data is available.
    ///   - _handshakePacketReady: Called to give current audio format.
    /// - Throws: If cannot communicate to Virtual USBAudioDriver.
    func makeSession(
        _packetReady: @escaping (_ ptr : UnsafeMutableRawPointer, _ len : Int) -> Void,
        _handshakePacketReady: @escaping (_ format : Data, _ useMic: Bool) throws -> Void,
        _useMic : Bool) throws {
        
        self.useMic = _useMic
        
        micAuhal = AUHALAudioPlayer()
        usbAuhal = AUHALAudioRecorder()
        
        // Get AudioDeviceID for our USBDriver.
        usbDriverDeviceID = try GetAudioDeviceIDByUID(uid: "USBAudioDevice_UID")
        
        // Register callbacks and send handshake packet describing audio format.
        packetReady = _packetReady
        usbAF = try GetAudioDescriptionFromDeviceID(id: usbDriverDeviceID)
        var handshakePayload = asbdToData(asbd: usbAF)
        
        if useMic {
            micDriverDeviceID = try GetAudioDeviceIDByUID(uid: "iOSMicDevice_UID")
            micAF = try GetAudioDescriptionFromDeviceID(id: micDriverDeviceID!)
            handshakePayload.append(asbdToData(asbd: micAF))
        }

        try _handshakePacketReady(handshakePayload, useMic)
        
        instantiateAUHAL(au: &usbAU)
        try initSystemAudioTransmission()
        
        if useMic {
            instantiateAUHAL(au: &micAU)
            try initIOSMicReceiving()
        }
        // Start polling virtual audio device.
        AudioUnitInitialize(usbAU!)
        if useMic { AudioUnitInitialize(micAU!) }
        AudioOutputUnitStart(usbAU!)
        if useMic { AudioOutputUnitStart(micAU!) }
        Logger.log(.log, TAG, "Started output unit")
    }
    
    func initIOSMicReceiving() throws {

        // Enable IO on the virtual speaker's output bus.
        var flag : UInt32 = 1;
        
        Logger.log(.log, TAG, "Enabling IO for iOS mic playback...")
        try handle(AudioUnitSetProperty(micAU,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             kAudioOutputBus, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag))))
        
        // Disable IO for the input of the virtual speaker.
        flag = 0
        try handle(AudioUnitSetProperty(micAU,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             kAudioInputBus, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag))))
        
        // Set iOSMicDriver device as input to HAL unit.
        Logger.log(.log, TAG, "Setting iOSMicDeviceID as CurrentDevice...")
        try handle(AudioUnitSetProperty(micAU,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             kAudioOutputBus, &micDriverDeviceID,
                             UInt32(MemoryLayout.size(ofValue: micDriverDeviceID))))

        Logger.log(.log, TAG, "Current Audio Format for iOS Mic: \(micAF!)...")
        
        // Set equal formats for input/output to avoid making AUHAL
        // convert PCM formats. For a diagram, see
        // https://developer.apple.com/library/archive/technotes/tn2091/_index.html
        
        // Set input stream format. this is the data format of audio coming
        // into the AUHAL unit's input scope. i.e. audio stream format from mic.
        Logger.log(.log, TAG, "Setting IO Stream formats for iOS Mic playback equal...")
        try handle(AudioUnitSetProperty(micAU,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             kAudioOutputBus,
                             &micAF,
                             UInt32(MemoryLayout.size(ofValue: micAF))))
        
        // Set output stream format. This is the data format of audio coming
        // out of AUHAL unit's input scope. i.e. audio stream format to transmit.
        /*try handle(AudioUnitSetProperty(micAU,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             kAudioOutputBus,
                             &micAF,
                             UInt32(MemoryLayout.size(ofValue: micAF))))*/
        
        // Request very small internal IO buffer sizes to increase frequency
        // by which we send packets. This reduces latency but stresses CPU.
        var internalIOBufferSize = 512
        Logger.log(.log, TAG, "Setting internal buffer size for Mic playback (\(internalIOBufferSize))...")
        try handle(AudioUnitSetProperty(micAU,
                             kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global,
                             kAudioOutputBus,
                             &internalIOBufferSize,
                             UInt32(MemoryLayout.size(ofValue: internalIOBufferSize))))
        
        Logger.log(.log, TAG, "Initting playback unit and adding callback...")
        micAuhal.initUnit(unit: micAU, outFormat: micAF)
        micAuhal.addPlaybackCallback()

        // Start polling virtual audio device.
     
        Logger.log(.log, TAG, "Started iOS Mic unit")
    }
    
    func initSystemAudioTransmission() throws {
        
        // Enable IO to signal to input scope. This is the element system
        // audio gets re-routed to by Virtual USBAudioDriver.
        var flag : UInt32 = 1;
        Logger.log(.log, TAG, "Enabling IO for USBAudioDriver input...")
        try handle(AudioUnitSetProperty(usbAU!,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             kAudioInputBus, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag))))
        
        // Disable IO for output scope. This scope is used by the system
        // audio to output our media sound
        flag = 0
        AudioUnitSetProperty(usbAU,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             kAudioOutputBus, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        // Set USBDriver device as input to HAL unit.
        Logger.log(.log, TAG, "Setting current input device to USBAudioDevice...")
        try handle(AudioUnitSetProperty(usbAU,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Input,
                             kAudioInputBus, &usbDriverDeviceID,
                             UInt32(MemoryLayout.size(ofValue: usbDriverDeviceID))))
  
        Logger.log(.log, TAG, "Current Audio Format: \(usbAF!)")
        
        // Set equal formats for input/output to avoid making AUHAL
        // convert PCM formats. For a diagram, see
        // https://developer.apple.com/library/archive/technotes/tn2091/_index.html
        
        // Set input stream format. this is the data format of audio coming
        // into the AUHAL unit's input scope. i.e. audio stream format from mic.
        Logger.log(.log, TAG, "Setting stream formats equal for USBAudioDevice...")
        /*try handle(AudioUnitSetProperty(usbAU,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             kAudioInputBus,
                             &usbAF,
                             UInt32(MemoryLayout.size(ofValue: usbAF))))*/
        
        // Set output stream format. This is the data format of audio coming
        // out of AUHAL unit's input scope. i.e. audio stream format to transmit.
        try handle(AudioUnitSetProperty(usbAU!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             kAudioInputBus,
                             &usbAF,
                             UInt32(MemoryLayout.size(ofValue: usbAF))))
        
        // Request very small internal IO buffer sizes to increase frequency
        // by which we send packets. This reduces latency but stresses CPU.
        var internalIOBufferSize = 128
        Logger.log(.log, TAG, "Setting internal IO buffer size for USBAudioDevice (\(internalIOBufferSize))...")
        try handle(AudioUnitSetProperty(usbAU,
                             kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global,
                             kAudioInputBus,
                             &internalIOBufferSize,
                             UInt32(MemoryLayout.size(ofValue: internalIOBufferSize))))
        
        Logger.log(.log, TAG, "Initting recording unit and adding callback...")
        usbAuhal.initUnit(unit: usbAU, inFormat: usbAF, pcmPacketReady: packetReady)
        usbAuhal.addRecordingCallback()
    }
    
    
    /// Throws error if errorCode
    func handle(_ errorCode: OSStatus) throws {
        if errorCode != kAudioHardwareNoError {
            let error = NSError(domain: NSOSStatusErrorDomain,
                                code: Int(errorCode),
                                userInfo: [NSLocalizedDescriptionKey : "CAError: \(errorCode)" ])
            var s = "kAudioUnitErr_"
            switch errorCode {
            case kAudioUnitErr_Initialized:
                s += "Initialized"; break
            case kAudioUnitErr_InvalidProperty:
                s += "InvalidProperty"; break
            case kAudioUnitErr_FailedInitialization:
                s += "FailedInitialization"; break
            case kAudioUnitErr_InvalidScope:
                s += "InvalidScope"; break
            case kAudioUnitErr_InvalidElement:
                s += "InvalidElement"; break
            case kAudioUnitErr_InvalidParameter:
                s += "InvalidParameter"; break
            case kAudioUnitErr_CannotDoInCurrentContext:
                s += "CannotDoInCurrentContext"; break
            case kAudioUnitErr_InvalidPropertyValue:
                s += "InvalidPropertyValue"; break
            case kAudioUnitErr_InvalidParameter:
                s += "InvalidParameter"; break
            case kAudioUnitErr_PropertyNotWritable:
                s += "PropertyNotWritable"; break
            default:
                s += "Generic"
            }

            Logger.log(.emergency, TAG, "Error: \(s)!")
            Logger.log(.emergency, TAG, "\(error)")
            throw error
        }
    }
    
    /// Uses VirtualUSBAudioDriver_getDeviceID(), then queries the device to
    /// find the currenttly configured audio stream format.
    /// - Throws: if cannot find USB Audio device or fail to query input stream.
    /// - Returns: AudioStreamBasicDescription currently set by USB Audio
    ///     device's input scope stream.
    func GetAudioDescriptionFromDeviceID(id : AudioDeviceID) throws -> AudioStreamBasicDescription {

        // Get the stream configuration of the device.
        var streamConfigAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0)
        
        var absd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: absd))

        try handle(AudioObjectGetPropertyData(id, &streamConfigAddress, 0, nil, &size, &absd))
        
        return absd
    }
    
    /// Finds the AudioDeviceID of the VirtualUSBAudio component
    /// - Throws: If cannot find ID
    func GetAudioDeviceIDByUID(uid : String) throws -> AudioDeviceID {

        // Construct the address of property which holds all available devices.
        var devicesPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster)
        
        var propertySize = UInt32(0)

        // Get the size of the property in the kAudioObjectSystemObject
        // so we can make space to store it
        try handle(AudioObjectGetPropertyDataSize(
                    AudioObjectID(kAudioObjectSystemObject),
                    &devicesPropertyAddress,
                    0,
                    nil,
                    &propertySize))
        
        // Get the number of devices
        let numberOfDevices = Int(propertySize) / MemoryLayout.size(ofValue: AudioDeviceID())

        // Create space to store the values
        var deviceIDs: [AudioDeviceID] = []
        for _ in 0 ..< numberOfDevices {
            deviceIDs.append(AudioDeviceID())
        }

        // Get the available devices
        try handle(AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &devicesPropertyAddress,
                    0,
                    nil,
                    &propertySize,
                    &deviceIDs))

        // Find our virtual device id by comparing UIDs.
        for id in deviceIDs {

            // Get the device UID
            var name: CFString = "" as CFString
            var propertySize = UInt32(MemoryLayout.size(ofValue: CFString.self))
            var deviceNamePropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster)
            let status = AudioObjectGetPropertyData(id,
                                                    &deviceNamePropertyAddress,
                                                    0, nil, &propertySize, &name)
            if status == .zero {
                if CFStringCompare(uid as CFString,
                                   name,
                                   CFStringCompareFlags(rawValue: 0))
                    == CFComparisonResult.compareEqualTo {
                    // Now that we know the device ID, return it
                    return id
                }
            }
        }
        throw NSError(domain: "Error_Domain", code: 100, userInfo: nil)
    }
}

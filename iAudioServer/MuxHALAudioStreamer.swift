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

let kUSBAudioSystemInputBus : UInt32 = 1;    // input bus element on AUHAL
let kUSBAudioSystemOutputBus : UInt32 = 0;   // output bus element on the AUHAL

/// Class in charge of streaming audio from the HAL plugin USBAudioDriver.
///
/// Uses AUHAL to communicate with the virtual device and issues resulting
/// data to callbacks passed into [makeSession](x-source-tag://makeSession)
class MuxHALAudioStreamer {
    
    /// Callback when new PCM Audio data packet has been rendered.
    var packetReady: ((UnsafeMutableRawPointer, Int) -> Void)!
    
    /// Audio stream format.
    var audioFormat: AudioStreamBasicDescription!
    
    /// The AUHAL Audio Unit.
    var audioUnit: AudioComponentInstance!
    
    /// Pre-Allocated AudioBufferList where PCM buffers get stored.
    var audioBufferList : UnsafeMutableAudioBufferListPointer!
    
    /// The buffer PCM data gets rendered into. Note: we only need one because
    /// we're using mono-channel audio.
    var audioBuffer : AudioBuffer!
    
    /// Print for debug.
    let debug = false

    /// Stops and disposes current AUHAL unit.
    func endSession() {
        AudioOutputUnitStop(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }
    
    /// Print wrapper.
    func log(_ s : String) {
        if debug { print(s) }
    }
    
    /// Serializes AudioStreamBasicDescription to Data for socket transmission
    func asbdToData(asbd : AudioStreamBasicDescription) -> Data {
        return withUnsafeBytes(of: asbd) {
            return Data(bytes: ($0.baseAddress)!,
                        count: MemoryLayout.size(ofValue: asbd))
        }
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
        _handshakePacketReady: @escaping (_ format : Data) throws -> Void) throws {
        
        // Register callbacks and send handshake packet describing audio format.
        packetReady = _packetReady
        audioFormat = try VirtualUSBAudioDriver_getBasicAudioDescription()
        try _handshakePacketReady(asbdToData(asbd: audioFormat))

        // Get AudioDeviceID for our USBDriver.
        var usbDriverDeviceID = try VirtualUSBAudioDriver_getDeviceID()

        // Find HAL audio component.
        var desc = AudioComponentDescription(
                    componentType:          kAudioUnitType_Output,
                    componentSubType:       kAudioUnitSubType_HALOutput,
                    componentManufacturer:  0,
                    componentFlags:         0,
                    componentFlagsMask:     0)
    
        let count = AudioComponentCount(&desc)
        if count == 0 {
            print("Failed to find AUHAL audio unit!")
            return
        }
        
        // Instantiate AUHAL audio unit.
        let comp = AudioComponentFindNext(nil, &desc)
        AudioComponentInstanceNew(comp!, &audioUnit)
        
        // Enable IO to signal to input scope. This is the element system
        // audio gets re-routed to by Virtual USBAudioDriver.
        var flag : UInt32 = 1;
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             kUSBAudioSystemInputBus, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        // Disable IO for output scope. This scope is used by the system
        // audio to output our media sound
        flag = 0
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             kUSBAudioSystemOutputBus, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        // Set USBDriver device as input to HAL unit.
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0, &usbDriverDeviceID,
                             UInt32(MemoryLayout.size(ofValue: usbDriverDeviceID)))
  
        log("Current Audio Format: \(audioFormat!)")
        
        // Set equal formats for input/output to avoid making AUHAL
        // convert PCM formats. For a diagram, see
        // https://developer.apple.com/library/archive/technotes/tn2091/_index.html
        
        // Set input stream format. this is the data format of audio coming
        // into the AUHAL unit's input scope. i.e. audio stream format from mic.
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             kUSBAudioSystemInputBus,
                             &audioFormat,
                             UInt32(MemoryLayout.size(ofValue: audioFormat)))
        
        // Set output stream format. This is the data format of audio coming
        // out of AUHAL unit's input scope. i.e. audio stream format to transmit.
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             kUSBAudioSystemInputBus,
                             &audioFormat,
                             UInt32(MemoryLayout.size(ofValue: audioFormat)))
        
        // Request very small internal IO buffer sizes to increase frequency
        // by which we send packets. This reduces latency but stresses CPU.
        var internalIOBufferSize = 128
        AudioUnitSetProperty(audioUnit,
                             kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global,
                             kUSBAudioSystemInputBus,
                             &internalIOBufferSize,
                             UInt32(MemoryLayout.size(ofValue: internalIOBufferSize)))
        
        // Create the callback to be called when new mic data is available.
        var callbackStruct = AURenderCallbackStruct()
        
        // Setup data callabcks. Pass pointer to this class instance.
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        callbackStruct.inputProc = {
           (inRefCon : UnsafeMutableRawPointer,
            ioActionFlags : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            inTimeStamp : UnsafePointer<AudioTimeStamp>,
            inBusNumber : UInt32,
            inNumberFrames : UInt32,
            ioData : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
           
            // Recast to this class instance.
            let _self = Unmanaged<MuxHALAudioStreamer>.fromOpaque(inRefCon).takeUnretainedValue()

            // Set audiobuffer to nil and compute buffer size. Note we only need
            // one buffer since we're taking in mono-channel virtual device.
            _self.audioBufferList[0].mData = nil
            _self.audioBufferList[0].mDataByteSize = inNumberFrames * _self.audioFormat.mBytesPerFrame
 
            // Request to fill audioBufferList.
            let res = AudioUnitRender(_self.audioUnit,
                                      ioActionFlags,
                                      inTimeStamp,
                                      inBusNumber,
                                      inNumberFrames,
                                      _self.audioBufferList.unsafeMutablePointer)
            _self.log("Rendered with status \(res) "
                    + "Got \(_self.audioBufferList.count) buffers "
                    + "of size \(_self.audioBufferList[0].mDataByteSize) "
                    + "and data \(_self.audioBufferList[0].mData)")
            
            // Ready to send buffers over to device.
            if _self.audioBufferList[0].mData != nil {
                _self.packetReady(_self.audioBufferList[0].mData!, Int(_self.audioBufferList[0].mDataByteSize))
            }
            else {
                print("Failed to populate buffers!")
            }
            return .zero
        }

        // Register our input callback.
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global,
                             kUSBAudioSystemInputBus,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
        
        // Allocate a single audioBuffer since we're dealing with mono-channel
        // input audio. Allocating buffers here once is more efficient.
        audioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        audioBuffer = AudioBuffer()
        audioBufferList[0] = audioBuffer
        audioBufferList[0].mData = nil
        audioBufferList[0].mDataByteSize = 0
        
        // Start polling virtual audio device.
        AudioUnitInitialize(audioUnit!)
        AudioOutputUnitStart(audioUnit!)
        print("Started output unit")
    }
    
    
    /// Throws error if errorCode
    func handle(_ errorCode: OSStatus) throws {
        if errorCode != kAudioHardwareNoError {
            let error = NSError(domain: NSOSStatusErrorDomain,
                                code: Int(errorCode),
                                userInfo: [NSLocalizedDescriptionKey : "CAError: \(errorCode)" ])
            print(error)
            throw error
        }
    }
    
    /// Uses VirtualUSBAudioDriver_getDeviceID(), then queries the device to
    /// find the currenttly configured audio stream format.
    /// - Throws: if cannot find USB Audio device or fail to query input stream.
    /// - Returns: AudioStreamBasicDescription currently set by USB Audio
    ///     device's input scope stream.
    func VirtualUSBAudioDriver_getBasicAudioDescription() throws -> AudioStreamBasicDescription {
        let id = try VirtualUSBAudioDriver_getDeviceID()
        
        // Get the stream configuration of the device. It's a list of audio buffers.
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
    func VirtualUSBAudioDriver_getDeviceID() throws -> AudioDeviceID {

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
                if CFStringCompare("USBAudioDevice_UID" as CFString,
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

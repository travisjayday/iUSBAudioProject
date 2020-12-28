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

class MuxHALAudioStreamer {
    
    var packetReady: ((UnsafeMutableRawPointer, Int) -> Void)?
    var audioFormat: AudioStreamBasicDescription!
    var audioUnit: AudioComponentInstance!
    var audioBufferList : UnsafeMutableAudioBufferListPointer!
    var audioBuffer : AudioBuffer!
    let debug = false

    func endSession() {
        AudioOutputUnitStop(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }
    
    func log(_ s : String) {
        if debug {
            print(s)
        }
    }
    
    func asbdToData(asbd : AudioStreamBasicDescription) -> Data {
        var data : NSMutableData = NSMutableData()
        // append ASBD
        withUnsafeBytes(of: asbd) { (ptr: UnsafeRawBufferPointer?) in
            data.append(NSMutableData(bytes: ptr?.baseAddress, length: MemoryLayout.size(ofValue: asbd)) as Data)
        }
        return data as Data
    }
     
    func makeSession(_packetReady: @escaping (_ ptr : UnsafeMutableRawPointer, _ len : Int) -> Void,
                     _handshakePacketReady: @escaping (_ format : Data) throws -> Void
    ) throws {
        packetReady = _packetReady
        
        audioFormat = try VirtualUSBAudioDriver_getBasicAudioDescription()
        try _handshakePacketReady(asbdToData(asbd: audioFormat))

        var usbDriverDeviceID = try VirtualUSBAudioDriver_getDeviceID()

        // find HAL audio component
        var desc = AudioComponentDescription(
                    componentType:          kAudioUnitType_Output,
                    componentSubType:       kAudioUnitSubType_HALOutput,
                    componentManufacturer:  0,
                    componentFlags:         0,
                    componentFlagsMask:     0
        )
    
        // need to do error checking
        let count = AudioComponentCount(&desc)
        print("found \(count) devices")
        
        // instantiate AUHAL audio unit
        var comp = AudioComponentFindNext(nil, &desc)
    
        AudioComponentInstanceNew(comp!, &audioUnit)
        
        // enable IO to signal we want to grab data
        var flag : UInt32 = 1;
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,
                             1, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        flag = 0
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             0, &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        
        
        var inputDevice : AudioDeviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout.size(ofValue: inputDevice))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size,
                                                       &inputDevice);

        
        // set USBDriver device as input to HAL unit
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0, &usbDriverDeviceID,
                             UInt32(MemoryLayout.size(ofValue: usbDriverDeviceID)))
        var DeviceFormat : AudioStreamBasicDescription = AudioStreamBasicDescription()
       
        var DesiredFormat : AudioStreamBasicDescription = AudioStreamBasicDescription()
          
        size = UInt32(MemoryLayout.size(ofValue: DesiredFormat));

        //Get the input device format
        AudioUnitGetProperty (audioUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      1,
                                      &DeviceFormat,
                                      &size);
    
        print(DeviceFormat)
        print(audioFormat)
        
        // set input stream format
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             1, &audioFormat,
                             UInt32(MemoryLayout.size(ofValue: audioFormat)))
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             1, &audioFormat,
                             UInt32(MemoryLayout.size(ofValue: audioFormat)))
        
        var internalIOBufferSize = 128
        AudioUnitSetProperty(audioUnit,
                             kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global,
                             1,
                             &internalIOBufferSize,
                             UInt32(MemoryLayout.size(ofValue: internalIOBufferSize)))
 
        audioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        audioBuffer = AudioBuffer()
        audioBufferList[0] = audioBuffer
        audioBufferList[0].mData = nil
        audioBufferList[0].mDataByteSize = 0
        
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        callbackStruct.inputProc = {
            ( inRefCon : UnsafeMutableRawPointer,
              ioActionFlags : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp : UnsafePointer<AudioTimeStamp>,
              inBusNumber : UInt32,
              inNumberFrames : UInt32,
              ioData : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
           
            let _self = Unmanaged<MuxHALAudioStreamer>.fromOpaque(inRefCon).takeUnretainedValue()

            _self.audioBufferList[0].mData = nil
            _self.audioBufferList[0].mDataByteSize = inNumberFrames * 2
 
            let res = AudioUnitRender(_self.audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _self.audioBufferList.unsafeMutablePointer)
            _self.log("render sttatus: \(res)")
            
            /*inTimeStamp.pointee.mSampleTime += Float64(inNumberFrames)*/
 
            _self.log("Got \(_self.audioBufferList.count) buffer of size \(_self.audioBufferList[0].mDataByteSize) and data \(_self.audioBufferList[0].mData)")
            // let p1 = NSData(bytes: bufferList[0].mData, length: Int(bufferList[0].mDataByteSize)) as Data
//            let p2 = NSData(bytes: bufferList[1].mData, length: Int(bufferList[1].mDataByteSize)) as Data
            _self.packetReady!(_self.audioBufferList[0].mData!, Int(_self.audioBufferList[0].mDataByteSize))

            return .zero
        }

        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global,
                             1,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
        
        AudioUnitInitialize(audioUnit!)
        AudioOutputUnitStart(audioUnit!)
        print("Started output unit")
    }
    
    func handle(_ errorCode: OSStatus) throws {
        if errorCode != kAudioHardwareNoError {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey : "CAError: \(errorCode)" ])
            print(error)
            throw error
        }
    }
    
    func VirtualUSBAudioDriver_getBasicAudioDescription() throws -> AudioStreamBasicDescription {
        let id = try VirtualUSBAudioDriver_getDeviceID()
        
        // Get the stream configuration of the device. It's a list of audio buffers.
        var streamConfigAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
        
        var absd = AudioStreamBasicDescription()
        var size : UInt32 = UInt32(MemoryLayout.size(ofValue: absd))

        try handle(AudioObjectGetPropertyData(id, &streamConfigAddress, 0, nil, &size, &absd))
        
        return absd
    }
    
    func VirtualUSBAudioDriver_getDeviceID() throws -> AudioDeviceID {

        // Construct the address of the property which holds all available devices
        var devicesPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        var propertySize = UInt32(0)

        // Get the size of the property in the kAudioObjectSystemObject so we can make space to store it
        try handle(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesPropertyAddress, 0, nil, &propertySize))
        

        // Get the number of devices by dividing the property address by the size of AudioDeviceIDs
        let numberOfDevices = Int(propertySize) / 4

        // Create space to store the values
        var deviceIDs: [AudioDeviceID] = []
        for _ in 0 ..< numberOfDevices {
            deviceIDs.append(AudioDeviceID())
        }

        // Get the available devices
        try handle(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesPropertyAddress, 0, nil, &propertySize, &deviceIDs))

        // Iterate
        for id in deviceIDs {

            // Get the device name
            var name: CFString = "" as CFString
            var propertySize = UInt32(MemoryLayout.size(ofValue: CFString.self))
            var deviceNamePropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
            try handle(AudioObjectGetPropertyData(id, &deviceNamePropertyAddress, 0, nil, &propertySize, &name))
           
            if CFStringCompare("USBAudioDevice_UID" as CFString, name, CFStringCompareFlags(rawValue: 0)) == CFComparisonResult.compareEqualTo {
                // Now that we know the device ID, return it
                return id
            }
        }
        throw NSError(domain: "Error_Domain", code: 100, userInfo: nil)
    }
}

//
//  AudioStreamer.swift
//  iAudioServer
//
//  Created by Travis Ziegler on 12/19/20.
//

import Foundation
import AVFoundation


class MuxAudioStreamer : NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    var ses: AVCaptureSession!
    var audioCon : AVCaptureConnection!
    var audioOut : AVCaptureAudioDataOutput!
    var packetReady: ((Data) -> Void)?

    var audioQueue: AudioQueueRef!
    var audioFormat: AudioStreamBasicDescription!

    func frameCallback(
        scopedSelf: MuxAudioStreamer!,
        audioBuf: AudioQueueBufferRef) {
        let data = NSData(bytes: audioBuf.pointee.mAudioData, length: Int(audioBuf.pointee.mAudioDataByteSize))
        scopedSelf.packetReady!(data as Data)
        AudioQueueEnqueueBuffer(audioQueue, audioBuf, 0, nil)
    }
    
    func endSession() {
        AudioQueueStop(audioQueue, true)
        AudioQueueDispose(audioQueue, true)
    }
    
    func asbdToData(asbd : AudioStreamBasicDescription) -> Data {
        var data : NSMutableData = NSMutableData()
        
        // append ASBD
        withUnsafeBytes(of: asbd) { (ptr: UnsafeRawBufferPointer?) in
            data.append(NSMutableData(bytes: ptr?.baseAddress, length: MemoryLayout.size(ofValue: asbd)) as Data)
        }
        print("converted ASBD \(asbd) to data with count \(data.count)")
        return data as Data
    }
     
    func makeSession(_packetReady: @escaping (_ img : Data) -> Void,
                     _handshakePacketReady: @escaping (_ format : Data) throws -> Void
    ) throws {
        packetReady = _packetReady
        
        audioFormat = try VirtualUSBAudioDriver_getBasicAudioDescription()
        try _handshakePacketReady(asbdToData(asbd: audioFormat))

        AudioQueueNewInput(
            &audioFormat,
            { (inUserData: UnsafeMutableRawPointer?,
               aqRef: AudioQueueRef,
               aqBuffer: AudioQueueBufferRef,
               timestamps: UnsafePointer<AudioTimeStamp>,
               inNumberPacketDescriptions: UInt32,
               inPacketDescs: UnsafePointer<AudioStreamPacketDescription>?) in
                let scopedSelf = Unmanaged<MuxAudioStreamer>.fromOpaque(inUserData!).takeUnretainedValue()
                scopedSelf.frameCallback(scopedSelf: scopedSelf,
                                         audioBuf: aqBuffer)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &audioQueue);
        
       
        var uid : CFString = "USBAudioDevice_UID" as CFString
        let size = MemoryLayout<CFString>.size
        let stat = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
   
        let bufferCap : UInt32 = 7056
        let numBufs = 2
        
        for _ in 0...numBufs {
            var buf : AudioQueueBufferRef!
            AudioQueueAllocateBuffer(audioQueue, bufferCap, &buf)
            AudioQueueEnqueueBuffer(audioQueue, buf, 0, nil)
        }
        
        AudioQueueStart(audioQueue, nil)
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

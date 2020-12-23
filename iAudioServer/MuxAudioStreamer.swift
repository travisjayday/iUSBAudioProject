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
        AudioQueueEnqueueBuffer(audioQueue, audioBuf, 0, nil)
        let data = NSData(bytes: audioBuf.pointee.mAudioData, length: Int(audioBuf.pointee.mAudioDataByteSize))
        scopedSelf.packetReady!(data as Data)
    }
    
    func endSession() {
        AudioQueueStop(audioQueue, true)
        AudioQueueDispose(audioQueue, true)
    }
    
    func craftHandshakePacket(asbd : AudioStreamBasicDescription) -> Data {
        let data : NSData
        withUnsafeBytes(of: &asbd) { (ptr: UnsafeRawBufferPointer) -> in
            let size = MemoryLayout.size(ofValue: asbd)
            print(size)
            data = NSData(bytes:ptr, length: MemoryLayout.size(ofValue: asbd))
        }
        return Data()
    }
     
    func makeSession(_packetReady: @escaping (_ img : Data) -> Void,
                     _handshakePacketReady: @escaping (_ format : Data) -> Void
    ) throws {
        packetReady = _packetReady
        
        audioFormat = try VirtualUSBAudioDriver_getBasicAudioDescription()
        _handshakePacketReady(craftHandshakePacket(asbd: audioFormat))

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
   
        let bufferCap : UInt32 = 5048
        var buf : AudioQueueBufferRef!
        AudioQueueAllocateBuffer(audioQueue, bufferCap, &buf)
        AudioQueueEnqueueBuffer(audioQueue, buf, 0, nil)
        AudioQueueStart(audioQueue, nil)
    }
    
    func VirtualUSBAudioDriver_getBasicAudioDescription() throws -> AudioStreamBasicDescription {

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
                // Now that we know the device ID, query it
                
                // Get the stream configuration of the device. It's a list of audio buffers.
                var streamConfigAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
                
                var absd = AudioStreamBasicDescription()
                var size : UInt32 = UInt32(MemoryLayout.size(ofValue: absd))

                try handle(AudioObjectGetPropertyData(id, &streamConfigAddress, 0, nil, &size, &absd))
                
                return absd
            }
        }
        throw NSError(domain: "Error_Domain", code: 100, userInfo: nil)
    }
}

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
     
    func makeSession(_packetReady: @escaping (_ img : Data) -> Void) {
        packetReady = _packetReady
        
        audioFormat = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        
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
        print("ALLOC")
        print(size)
        let stat = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
   
        print(stat)
        
        let bufferCap : UInt32 = 5048
        var buf : AudioQueueBufferRef!
        AudioQueueAllocateBuffer(audioQueue, bufferCap, &buf)
        AudioQueueEnqueueBuffer(audioQueue, buf, 0, nil)
        AudioQueueStart(audioQueue, nil)
    }
    
    //func getVirtualUSBDriverID : AudioQueueID
    
    func handle(_ errorCode: OSStatus) throws {
        if errorCode != kAudioHardwareNoError {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey : "CAError: \(errorCode)" ])
            print(error)
            throw error
        }
    }

    func getInputDevices() throws -> [AudioDeviceID] {

        var inputDevices: [AudioDeviceID] = []

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

            // Get the device name for fun
            var name: CFString = "" as CFString
            var propertySize = UInt32(MemoryLayout.size(ofValue: CFString.self))
            var deviceNamePropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
            try handle(AudioObjectGetPropertyData(id, &deviceNamePropertyAddress, 0, nil, &propertySize, &name))

            // Check the input scope of the device for any channels. That would mean it's an input device

            // Get the stream configuration of the device. It's a list of audio buffers.
            var streamConfigAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: 0)

            // Get the size so we can make room again
            try handle(AudioObjectGetPropertyDataSize(id, &streamConfigAddress, 0, nil, &propertySize))

            // Create a buffer list with the property size we just got and let core audio fill it
            let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(propertySize))
            try handle(AudioObjectGetPropertyData(id, &streamConfigAddress, 0, nil, &propertySize, audioBufferList.unsafeMutablePointer))

            // Get the number of channels in all the audio buffers in the audio buffer list
            var channelCount = 0
            for i in 0 ..< Int(audioBufferList.unsafeMutablePointer.pointee.mNumberBuffers) {
                channelCount = channelCount + Int(audioBufferList[i].mNumberChannels)
            }

            free(audioBufferList.unsafeMutablePointer)

            // If there are channels, it's an input device
            if channelCount > 0 {
                Swift.print("Found input device '\(name)' with \(channelCount) channels")
                inputDevices.append(id)
            }
        }

        return inputDevices
    }
}

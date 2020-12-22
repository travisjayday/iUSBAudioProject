//
//  AudioStreamer.swift
//  iAudioServer
//
//  Created by Travis Ziegler on 12/19/20.
//

import Foundation
import AVFoundation


class MuxHALAudioStreamer : NSObject {
    
    var packetReady: ((Data) -> Void)?
    
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

    func makeSession(_packetReady: @escaping (_ img : Data) -> Void) {
        packetReady = _packetReady
        do {
        let devices = try getInputDevices()
            for dev in devices {
                print(dev)
            }
        }
        catch {
            print("ERRORR")
        }
        
        let audioFormat = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        
        var desc = AudioComponentDescription(componentType: 0, componentSubType: 0, componentManufacturer: 0, componentFlags: AudioComponentFlags.sandboxSafe.rawValue, componentFlagsMask: 0)
        let count : UInt32 = AudioComponentCount(&desc)
        print("Found \(count) audio devices")
        var comp: AudioComponent? = nil
        for i in 0...count {
            comp = AudioComponentFindNext(comp, &desc)!
            var name : Unmanaged<CFString>?
            AudioComponentCopyName(comp!, &name)
            print(name)
        }
        
        //AudioComponentGetDescription(comp, &desc)
        print("Found device")
        print(desc)
    }
}

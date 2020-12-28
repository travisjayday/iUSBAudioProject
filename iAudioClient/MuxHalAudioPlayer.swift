//
//  MuxHalAudioPlayer.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/26/20.
//

import Foundation
import AVFoundation

class MuxHALAudioPlayer {

    var initted = false
    
    var audioFormat: AudioStreamBasicDescription!
    var audioUnit : AudioComponentInstance!
    var readyData : Data!
    var timeStart : Double = 0
    var bytesReceived : Int = 0
    let semaphore = DispatchSemaphore(value: 1)
    var internalIOBufferDuration : Double = 0.0
    
    func stopPlaying() {
        let speed = (Double(bytesReceived) / (Date().timeIntervalSince1970 - timeStart))
        print("SPEED: \(speed)bytes/s");
        AudioOutputUnitStop(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }
    
    func playPacket(pcm: Data, format: AudioStreamBasicDescription) {
        if !initted {
            initted = true
            audioFormat = format
            initPlayFromHelloPacket()
            readyData = Data()
            timeStart = Date().timeIntervalSince1970
            return
        }
        var newBytes = [UInt8](pcm)
        bytesReceived += newBytes.count
        let newBytesCount = newBytes.count
        
        semaphore.wait()
        readyData.append(pcm)
        semaphore.signal()
    }

    func initPlayFromHelloPacket() {
        
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        
        var inComp = AudioComponentFindNext(nil, &desc)
        
        AudioComponentInstanceNew(inComp!, &audioUnit)
        /*
         #define kOutputBus 0
         #define kInputBus 1
         */
        
        // setup playback io
        var flag : UInt32 = 1;
        AudioUnitSetProperty(audioUnit!,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             0, &flag, 4)
        
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             0, &audioFormat, UInt32(MemoryLayout.size(ofValue: audioFormat)))
        
        
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0, &audioFormat, UInt32(MemoryLayout.size(ofValue: audioFormat)))

        

        do {
            var ses = AVAudioSession.sharedInstance()
            try ses.setPreferredIOBufferDuration(TimeInterval(0.01))
            self.internalIOBufferDuration = ses.ioBufferDuration
        }
        catch {
            print("FAILED TO SET IO Duration")
        }
        
        print("Configured for internalIOBufersize=\(internalIOBufferDuration) ")
        
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProc = {
            ( inRefCon : UnsafeMutableRawPointer,
              ioActionFlags : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp : UnsafePointer<AudioTimeStamp>,
              inBusNumber : UInt32,
              inNumberFrames : UInt32,
              ioData : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
            print("Inside audio playback callback need to fill \(inNumberFrames) of data")
            let _self = Unmanaged<MuxHALAudioPlayer>.fromOpaque(inRefCon).takeUnretainedValue()
            if ioData != nil {
                let abl = UnsafeMutableAudioBufferListPointer(ioData)!
                _self.semaphore.wait()
                var buffer = abl[0]
                buffer.mDataByteSize = UInt32(round(_self.audioFormat.mSampleRate * Double(_self.audioFormat.mBytesPerFrame) * _self.internalIOBufferDuration))
                print("Computed size of \(buffer.mDataByteSize) but needed ")
                buffer.mDataByteSize = inNumberFrames * 2
                var data = Array.init(repeating: 0 as UInt8, count: Int(buffer.mDataByteSize))
                print("\(_self.readyData.count) available data")
                if _self.readyData.count > data.count {
                    data.replaceSubrange(data.startIndex..<data.startIndex+data.count, with: _self.readyData.subdata(in: _self.readyData.startIndex..<_self.readyData.startIndex+data.count))
                    _self.readyData.removeFirst(data.count)
                }
                else {
                    print("not enough ready dat")
                    //data.replaceSubrange(0..<data.count, with: _self.readyData)
                    //
                }
                /*if _self.readyData.count > 256 {
                    _self.readyData.removeLast(256)
                }*/
                print("Filling \(data.count)")
                memcpy(buffer.mData, &data, data.count)
                buffer.mDataByteSize = UInt32(data.count)
                buffer.mNumberChannels = 1
                
                if abl.count == 2 {
                    var buffer2 = abl[1]
                    memcpy(buffer2.mData, &data, data.count)
                    buffer2.mDataByteSize = UInt32(data.count)
                    buffer2.mNumberChannels = 1
                }
            
                _self.semaphore.signal()
            }
            
            return .zero
        }
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Global,
                             0,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
        
        AudioUnitInitialize(audioUnit!)
        AudioOutputUnitStart(audioUnit!)
    }
}

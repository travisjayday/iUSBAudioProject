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
    var pcmBuf : Array<UInt8>!
    var debug = false
    
    /// Print wrapper.
    func log(_ s : String) {
        if debug { print(s) }
    }
    
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
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             0,
                             &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             0,
                             &audioFormat,
                             UInt32(MemoryLayout.size(ofValue: audioFormat)))
        
        
        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &audioFormat,
                             UInt32(MemoryLayout.size(ofValue: audioFormat)))

        do {
            let ses = AVAudioSession.sharedInstance()
            try ses.setPreferredIOBufferDuration(TimeInterval(0.01))
            self.internalIOBufferDuration = ses.ioBufferDuration
        }
        catch {
            print("FAILED TO SET IO Duration")
        }
        
        print("Configured for internalIOBufersize=\(internalIOBufferDuration)")
        
        pcmBuf = Array.init(repeating: 0 as UInt8, count: Int(8192))
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        callbackStruct.inputProc = {
             (inRefCon : UnsafeMutableRawPointer,
              ioActionFlags : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp : UnsafePointer<AudioTimeStamp>,
              inBusNumber : UInt32,
              inNumberFrames : UInt32,
              ioData : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
            //print("Inside audio playback callback need to fill \(inNumberFrames) of data")
            let _self = Unmanaged<MuxHALAudioPlayer>.fromOpaque(inRefCon).takeUnretainedValue()
            if ioData == nil {
                return .zero
            }
            
            _self.semaphore.wait()
            
            let abl = UnsafeMutableAudioBufferListPointer(ioData)!
            var buffer = abl[0]
            let bufferSize = Int(inNumberFrames * _self.audioFormat.mBytesPerFrame)
            buffer.mDataByteSize = UInt32(bufferSize)
            buffer.mNumberChannels = 1
            

            _self.log("\(_self.readyData.count) available data")
            var data = _self.pcmBuf!
            
            
            let psi = data.startIndex
            let rsi = _self.readyData.startIndex
            if _self.readyData.count > bufferSize {
                data.replaceSubrange(
                    psi ..< psi+bufferSize,
                    with: _self.readyData.subdata(in: rsi ..< rsi+bufferSize))
                _self.readyData.removeFirst(bufferSize)
            }
            else {
                data.resetBytes(in: psi ..< psi+bufferSize)
                _self.log("not enough ready dat")
                
            }
            
            _self.log("Filling \(_self.pcmBuf.count)")
            memcpy(buffer.mData, &data, bufferSize)
            
            if abl.count == 2 {
                var buffer2 = abl[1]
                buffer2.mData = buffer.mData
                buffer2.mDataByteSize = buffer.mDataByteSize
                buffer2.mNumberChannels = buffer.mNumberChannels
            }
        
            _self.semaphore.signal()
        
            return .zero
        }
        
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

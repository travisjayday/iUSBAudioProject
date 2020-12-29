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
    var sRingbuffer : [UInt8]!
    var sRingbufferWO = 0
    var sRingbufferRO = 0
    var timeStart : Double = 0
    var bytesReceived : Int = 0
    let semaphore = DispatchSemaphore(value: 1)
    var internalIOBufferDuration : Double = 0.0
    var pcmBuf : Array<UInt8>!
    var debug = true
    
    /// Print wrapper.
    func log(_ s : String) {
        if debug { print(s) }
    }
    
    func stopPlaying() {
        let speed = (Double(bytesReceived) / (Date().timeIntervalSince1970 - timeStart))
        print("SPEED: \(speed)bytes/s");
        AudioOutputUnitStop(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        initted = false
    }
    
    func playPacket(pcm: Data, format: AudioStreamBasicDescription) {
        if !initted {
            initted = true
            audioFormat = format
            initPlayFromHelloPacket()
            sRingbuffer = Array.init(repeating: 0 as UInt8, count: Int(8192 * 20))
            timeStart = Date().timeIntervalSince1970
            return
        }
        bytesReceived += pcm.count

        semaphore.wait()
        
        // inclusive of current byte pointed to by WO
        let spaceUntilBufferEnd = sRingbuffer.count - sRingbufferWO
        if pcm.count < spaceUntilBufferEnd {
            pcm.withUnsafeBytes({pbp in sRingbuffer.withUnsafeMutableBytes({rbp in
                memcpy(rbp.baseAddress?.advanced(by: sRingbufferWO), pbp.baseAddress, pcm.count)
            })})
            sRingbufferWO += pcm.count
        } else {
            pcm.withUnsafeBytes({pbp in sRingbuffer.withUnsafeMutableBytes({rbp in
                memcpy(rbp.baseAddress?.advanced(by: sRingbufferWO),
                       pbp.baseAddress,
                       spaceUntilBufferEnd)
                memcpy(rbp.baseAddress,
                       pbp.baseAddress?.advanced(by: spaceUntilBufferEnd),
                       pcm.count - spaceUntilBufferEnd)
                sRingbufferWO = pcm.count - spaceUntilBufferEnd
            })})
        }
        sRingbufferWO %= sRingbuffer.count
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
            try ses.setPreferredIOBufferDuration(TimeInterval(0.005))
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
             (inRefCon       : UnsafeMutableRawPointer,
              ioActionFlags  : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp    : UnsafePointer<AudioTimeStamp>,
              inBusNumber    : UInt32,
              inNumberFrames : UInt32,
              ioData         : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
            
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
            
            _self.log(" available data. Need to fill" +
                "\(inNumberFrames) frames of data")
            var data = _self.pcmBuf!
            
            
            if _self.sRingbufferWO > _self.sRingbufferRO {
                let freshBytes = Int(_self.sRingbufferWO - _self.sRingbufferRO)
                print("Distance between WO and RO is = \(freshBytes)")
                //_self.sRingbufferRO = _self.sRingbufferWO - bufferSize

                if freshBytes >= bufferSize {
                    _self.sRingbuffer.withUnsafeMutableBytes({rbp in
                        _self.pcmBuf.withUnsafeMutableBytes({pbp in
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize)
                        })
                    })
                    _self.sRingbufferRO += bufferSize
                }
                else  {
                    _self.sRingbuffer.withUnsafeMutableBytes({rbp in
                        _self.pcmBuf.withUnsafeMutableBytes({pbp in
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize - freshBytes)
                        })
                    })
                    _self.sRingbufferRO += bufferSize - freshBytes
                }
                if freshBytes >= Int(2 * Double(bufferSize))  {
                    _self.sRingbufferRO += Int(round(0.25 * Double(bufferSize)))
                }
            }
            else {
                let spaceUntilBufferEnd = _self.sRingbuffer.count - _self.sRingbufferRO
                _self.sRingbuffer.withUnsafeMutableBytes({rbp in
                    _self.pcmBuf.withUnsafeMutableBytes({pbp in
                        if spaceUntilBufferEnd >= bufferSize {
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize)
                            _self.sRingbufferRO += bufferSize
                        }
                        else {
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), spaceUntilBufferEnd)
                            memcpy(pbp.baseAddress?.advanced(by: spaceUntilBufferEnd), rbp.baseAddress, bufferSize - spaceUntilBufferEnd)
                            _self.sRingbufferRO = bufferSize - spaceUntilBufferEnd
                        }
                    })
                })
            }
            _self.sRingbufferRO %= _self.sRingbuffer.count
            /*
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
                
            }*/
            
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

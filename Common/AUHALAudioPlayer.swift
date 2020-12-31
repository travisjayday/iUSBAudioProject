//
//  AUHALAudioPlayer.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/29/20.
//

import Foundation
import AVFoundation

let kAudioSystemInputBus : UInt32 = 1;    // input bus element on AUHAL
let kAudioSystemOutputBus : UInt32 = 0;   // output bus element on the AUHAL


class AUHALAudioPlayer {
    var audioUnit : AudioComponentInstance!
    var sRingbuffer : [UInt8]!
    var sRingbufferWO = 0
    var sRingbufferRO = 0
    let semaphore = DispatchSemaphore(value: 1)
    var outAudioF: AudioStreamBasicDescription!
    var pcmBuf : Array<UInt8>!
    var initted = false
    let TAG = "AUHALAudioPlayer"
    
    func initUnit(unit: AudioComponentInstance, outFormat: AudioStreamBasicDescription) {
        sRingbuffer = Array.init(repeating: 0 as UInt8, count: Int(8192 * 300))
        audioUnit = unit
        outAudioF = outFormat
    }
    
    func enqueuePCM(_ pcm : UnsafeMutablePointer<Int8>, _ len : Int) {
        semaphore.wait()
        
        // inclusive of current byte pointed to by WO
        let spaceUntilBufferEnd = sRingbuffer.count - sRingbufferWO
        if len < spaceUntilBufferEnd {
            sRingbuffer.withUnsafeMutableBytes({rbp in
                memcpy(rbp.baseAddress?.advanced(by: sRingbufferWO), pcm, len)
            })
            sRingbufferWO += len
        } else {
            sRingbuffer.withUnsafeMutableBytes({rbp in
                memcpy(rbp.baseAddress?.advanced(by: sRingbufferWO),
                       pcm,
                       spaceUntilBufferEnd)
                memcpy(rbp.baseAddress,
                       pcm.advanced(by: spaceUntilBufferEnd),
                       len - spaceUntilBufferEnd)
                sRingbufferWO = len - spaceUntilBufferEnd
            })
        }
        sRingbufferWO %= sRingbuffer.count
        semaphore.signal()
    }
    
    func addPlaybackCallback() {
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
            
            let _self = Unmanaged<AUHALAudioPlayer>.fromOpaque(inRefCon).takeUnretainedValue()
            if ioData == nil {
                return .zero
            }
            
            _self.semaphore.wait()
            
            let abl = UnsafeMutableAudioBufferListPointer(ioData)!
            var buffer = abl[0]
            let bufferSize = Int(inNumberFrames * _self.outAudioF.mBytesPerFrame)
            buffer.mDataByteSize = UInt32(bufferSize)
            buffer.mNumberChannels = 1
            
            Logger.log(.verbose, _self.TAG, "Need to fill \(inNumberFrames) frames")
            var data = _self.pcmBuf!
            
            // write offet is ahead of read offset. this is good
            if _self.sRingbufferWO >= _self.sRingbufferRO {
                let freshBytes = Int(_self.sRingbufferWO - _self.sRingbufferRO)
                Logger.log(.verbose, _self.TAG, "Distance between WO and RO is = \(freshBytes)")

                if freshBytes >= bufferSize {
                    _self.sRingbuffer.withUnsafeMutableBytes({rbp in
                        _self.pcmBuf.withUnsafeMutableBytes({pbp in
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize)
                        })
                    })
                    _self.sRingbufferRO += bufferSize
                }
                else  {
                    // Not enough buffer space. Skip packet
                }
                if freshBytes >= Int(2 * Double(bufferSize))  {
                    _self.sRingbufferRO += Int(round(0.25 * Double(bufferSize)))
                }
                if freshBytes >= Int(4 * Double(bufferSize))  {
                    _self.sRingbufferRO += Int(round(1 * Double(bufferSize)))
                }
            }
            // read offet is ahead of write offset. this is bad
            else {
                let spaceUntilBufferEnd = _self.sRingbuffer.count - _self.sRingbufferRO
                _self.sRingbuffer.withUnsafeMutableBytes({rbp in
                    _self.pcmBuf.withUnsafeMutableBytes({pbp in
                        if spaceUntilBufferEnd >= bufferSize {
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize)
                            _self.sRingbufferRO += bufferSize
                        }
                        else {
                            // copy tail end of ringbuffer into first half of active buffer
                            memcpy(pbp.baseAddress, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), spaceUntilBufferEnd)
                            // copy beginning of ring buffer into into second half of active buffer
                            memcpy(pbp.baseAddress?.advanced(by: spaceUntilBufferEnd), rbp.baseAddress, bufferSize - spaceUntilBufferEnd)
                            _self.sRingbufferRO = bufferSize - spaceUntilBufferEnd
                        }
                    })
                })
            }
            _self.sRingbufferRO %= _self.sRingbuffer.count
       
            Logger.log(.verbose, _self.TAG, "Filling audio output buffer with data " +
                    "\(_self.pcmBuf[0]), \(_self.pcmBuf[1]), \(_self.pcmBuf[2])")
            
            // data = data.map { max($0 &- 20, 0) }
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
                             kAudioSystemOutputBus,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
    }
}

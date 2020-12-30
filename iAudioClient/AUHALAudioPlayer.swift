//
//  AUHALAudioPlayer.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/29/20.
//

import Foundation
import AVFoundation

class AUHALAudioPlayer {
    var audioUnit : AudioComponentInstance!
    var sRingbuffer : [UInt8]!
    var sRingbufferWO = 0
    var sRingbufferRO = 0
    let semaphore = DispatchSemaphore(value: 1)
    var outAudioF: AudioStreamBasicDescription!
    var pcmBuf : Array<UInt8>!
    var debug = true
    var initted = false
    
    /// Print wrapper.
    func log(_ s : String) {
        if debug { print(s) }
    }
    
    func initUnit(unit: AudioComponentInstance, outFormat: AudioStreamBasicDescription) {
        sRingbuffer = Array.init(repeating: 0 as UInt8, count: Int(8192 * 20))
        audioUnit = unit
        outAudioF = outFormat
    }
    
    func enqueuePCM(pcm : Data) {
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
    
    func stopAudioUnit() {

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
                             kAudioSystemOutputBus,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
    }
}

//
//  AUHALAudioPlayer.swift
//  iAudio CommonTools
//
//  Created by Travis Ziegler on 12/29/20.
//

import Foundation
import AVFoundation

let kAudioSystemInputBus : UInt32 = 1;    // input bus element on AUHAL
let kAudioSystemOutputBus : UInt32 = 0;   // output bus element on the AUHAL

/// Abstratction for playing audio data out of an AUHAL unit. Configure the unit,
/// pass it in, feed raw mono-channeled LPCM data to this class, and it will take care
/// playing it. Uses ringbuffer to copy and read data.
class AUHALAudioPlayer {
    
    /// The AU that has a speaker attached to it's output.
    var audioUnit : AudioComponentInstance!
    
    /// The Socket Ringbuffer to store incoming data and then read from
    /// it to fill system io audio buffers.
    var sRingbuffer : [UInt8]!
    
    /// Size of ringbuffer in bytes. The longer this is, the more ringbuffer will
    /// act like an infinitely sized buffer, probably less audio artifcats on
    /// slower connections. Make big.
    let kRingBufferSize = 8192 * 300
    
    /// The index in the ringbuffer which we will write fresh data to.
    var sRingbufferWO = 0
    
    /// The index in the ringbuffer from which we will start reading fresh data.
    var sRingbufferRO = 0
    
    /// Mutex to prevent cross thread access to ringbuffer. 
    let semaphore = DispatchSemaphore(value: 1)
    
    /// Format of audio being fed into the AU.
    var outAudioF: AudioStreamBasicDescription!
    
    /// Debugging.
    let TAG = "AUHALAudioPlayer"
    
    /// Allocate ringbuffer, set up.
    func initUnit(unit: AudioComponentInstance, outFormat: AudioStreamBasicDescription) {
        sRingbuffer = Array.init(repeating: 0 as UInt8, count: kRingBufferSize)
        audioUnit = unit
        outAudioF = outFormat
    }
    
    /// Writes PCM data into the ringbuffer.
    func enqueuePCM(_ pcm : UnsafeMutablePointer<Int8>, _ len : Int) {
        // lock mutex.
        semaphore.wait()
        
        // Inclusive of current byte pointed to by WO.
        let spaceUntilBufferEnd = sRingbuffer.count - sRingbufferWO
        if len < spaceUntilBufferEnd {
            // data fits in ringbuffer, so just copy it
            sRingbuffer.withUnsafeMutableBytes({rbp in
                memcpy(rbp.baseAddress?.advanced(by: sRingbufferWO), pcm, len)
            })
            sRingbufferWO += len
        } else {
            // data does not fit, so need to wrap around to start.
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
        
        // releaes mutex.
        semaphore.signal()
    }
    
    func addPlaybackCallback() {
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
                Logger.log(.emergency, _self.TAG, "iOBuffer is NULL! Refusing to play audio.")
                return .zero
            }
            
            _self.semaphore.wait()
            
            let abl = UnsafeMutableAudioBufferListPointer(ioData)!
            var buffer = abl[0]
            let bufferSize = Int(inNumberFrames * _self.outAudioF.mBytesPerFrame)
            buffer.mDataByteSize = UInt32(bufferSize)
            buffer.mNumberChannels = 1
            
            Logger.log(.verbose, _self.TAG, "Need to fill \(inNumberFrames) frames")

            // write offet is ahead of read offset. this is good
            if _self.sRingbufferWO >= _self.sRingbufferRO {
                let freshBytes = Int(_self.sRingbufferWO - _self.sRingbufferRO)
                Logger.log(.verbose, _self.TAG, "Distance between WO and RO is = \(freshBytes)")

                if freshBytes >= bufferSize {
                    _self.sRingbuffer.withUnsafeMutableBytes({rbp in
                        memcpy(buffer.mData, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize)
                    })
                    _self.sRingbufferRO += bufferSize
                }
                else  {
                    // Not enough buffer space. Skip packet. This will create
                    // audio artifcat but hopefully stream will catch up next
                    // packet, so we have enough data in the future. Set silence.
                    memset(buffer.mData, 0, bufferSize)
                }
                
                // If RO is lagging hard behind WO, we need to catch up to it
                // to get low latency stream. Thus, artifically move RO forward.
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
                    if spaceUntilBufferEnd >= bufferSize {
                        memcpy(buffer.mData, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), bufferSize)
                        _self.sRingbufferRO += bufferSize
                    }
                    else {
                        // copy tail end of ringbuffer into first half of active buffer
                        memcpy(buffer.mData, rbp.baseAddress!.advanced(by: _self.sRingbufferRO), spaceUntilBufferEnd)
                        // copy beginning of ring buffer into into second half of active buffer
                        memcpy(buffer.mData?.advanced(by: spaceUntilBufferEnd), rbp.baseAddress, bufferSize - spaceUntilBufferEnd)
                        _self.sRingbufferRO = bufferSize - spaceUntilBufferEnd
                    }
                })
            }
            _self.sRingbufferRO %= _self.sRingbuffer.count
       
            // If system wants us to fill dual-channel audio (for example, if
            // using headphones on iOS device, just point the second channel to
            // the first to emulate stereo).
            if abl.count == 2 {
                var buffer2 = abl[1]
                buffer2.mData = buffer.mData
                buffer2.mDataByteSize = buffer.mDataByteSize
                buffer2.mNumberChannels = buffer.mNumberChannels
            }
        
            _self.semaphore.signal()
        
            return .zero
        }
        
        // Register render callback on audio unit.
        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Global,
                             kAudioSystemOutputBus,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
    }
}

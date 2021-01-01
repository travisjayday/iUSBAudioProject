//
//  AUHALAudioRecorder.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/29/20.
//

import Foundation
import AVFoundation

class AUHALAudioRecorder {
    var audioUnit : AudioComponentInstance!
    var inAudioF : AudioStreamBasicDescription!
    
    /// Callback when new PCM Audio data packet has been rendered.
    var micPacketReady: ((UnsafeMutableRawPointer, Int) -> Void)?
    
    /// Pre-Allocated AudioBufferList where PCM buffers get stored.
    var audioBufferList : UnsafeMutableAudioBufferListPointer!
    
    /// The buffer PCM data gets rendered into. Note: we only need one because
    /// we're using mono-channel audio.
    var audioBuffer : AudioBuffer!
    
    let TAG = "AUHALAudioRecorder"
    
    func initUnit(unit: AudioComponentInstance, inFormat: AudioStreamBasicDescription, pcmPacketReady: ((_ ptr : UnsafeMutableRawPointer, _ len : Int) -> Void)?) {
        
        micPacketReady = pcmPacketReady
        
        // Allocate a single audioBuffer since we're dealing with mono-channel
        // input audio. Allocating buffers here once is more efficient.
        audioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        audioBuffer = AudioBuffer()
        audioBufferList[0] = audioBuffer
        audioBufferList[0].mData = nil
        audioBufferList[0].mDataByteSize = 0
        
        audioUnit = unit
        inAudioF = inFormat
    }
    
    func addRecordingCallback() {
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        callbackStruct.inputProc = {
             (inRefCon       : UnsafeMutableRawPointer,
              ioActionFlags  : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp    : UnsafePointer<AudioTimeStamp>,
              inBusNumber    : UInt32,
              inNumberFrames : UInt32,
              ioData         : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
            
            let _self = Unmanaged<AUHALAudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
            
            // Set audiobuffer to nil and compute buffer size. Note we only need
            // one buffer since we're taking in mono-channel virtual device.
            _self.audioBufferList[0].mData = nil
            _self.audioBufferList[0].mDataByteSize = inNumberFrames * _self.inAudioF.mBytesPerFrame
 
            // Request to fill audioBufferList.
            let res = AudioUnitRender(_self.audioUnit,
                                      ioActionFlags,
                                      inTimeStamp,
                                      inBusNumber,
                                      inNumberFrames,
                                      _self.audioBufferList.unsafeMutablePointer)
            Logger.log(.verbose, _self.TAG, "Rendered with status \(res) "
                    + "Got \(_self.audioBufferList.count) buffers "
                    + "of size \(_self.audioBufferList[0].mDataByteSize) "
                    + "and data \(_self.audioBufferList[0].mData) "
                    + "with num channels \(_self.audioBufferList[0].mNumberChannels) "
                    + "so recorded \(inNumberFrames) of data")
            
            // Ready to send buffers over to device.
            if _self.audioBufferList[0].mData != nil {
                _self.micPacketReady!(_self.audioBufferList[0].mData!, Int(_self.audioBufferList[0].mDataByteSize))
            }
            else {
                Logger.log(.emergency, _self.TAG, "Failed to populate buffers!")
            }
            return .zero
        }
        
        AudioUnitSetProperty(audioUnit,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global,
                             kAudioSystemInputBus,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
    }
}

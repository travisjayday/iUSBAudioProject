//
//  MuxHalAudioPlayer.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/26/20.
//

import Foundation
import AVFoundation

let kAudioSystemInputBus : UInt32 = 1;    // input bus element on AUHAL
let kAudioSystemOutputBus : UInt32 = 0;   // output bus element on the AUHAL

// See http://atastypixel.com/blog/using-remoteio-audio-unit/ for an example.
class ClientAUHALInterface {

    var initted = false
    
    var audioOutUnit: AudioComponentInstance!
    var auhalPlayer: AUHALAudioPlayer!
    var outAudioF: AudioStreamBasicDescription!
    
    var inAudioF: AudioStreamBasicDescription!
   
    var timeStart : Double = 0
    var bytesReceived : Int = 0
    var internalIOBufferDuration : Double = 0.0
    var debug = true
    var useMic = false
    
    /// Callback when new PCM Audio data packet has been rendered.
    var micPacketReady: ((UnsafeMutableRawPointer, Int) -> Void)?
    
    /// Pre-Allocated AudioBufferList where PCM buffers get stored.
    var audioBufferList : UnsafeMutableAudioBufferListPointer!
    
    /// The buffer PCM data gets rendered into. Note: we only need one because
    /// we're using mono-channel audio.
    var audioBuffer : AudioBuffer!
    
    /// Print wrapper.
    func log(_ s : String) {
        if debug { print(s) }
    }
    
    init(_micPacketReady: ((_ ptr : UnsafeMutableRawPointer, _ len : Int) -> Void)?) {
        micPacketReady = _micPacketReady
    }
    
    func endSession() {
        let speed = (Double(bytesReceived) / (Date().timeIntervalSince1970 - timeStart))
        print("SPEED: \(speed)bytes/s");

        initted = false
    }
    
    func initUnit(outFormat: AudioStreamBasicDescription, inFormat: AudioStreamBasicDescription?) {
        if !initted {
            initted = true
            if inFormat != nil {
                useMic = true
                inAudioF = inFormat
            }
            initPlayFromHelloPacket()
            timeStart = Date().timeIntervalSince1970
        }
    }
    
    func playPacket(pcm: Data) {
        bytesReceived += pcm.count
        auhalPlayer.enqueuePCM(pcm: pcm)
    }

    func initPlayFromHelloPacket() {
        
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        
        var inComp = AudioComponentFindNext(nil, &desc)
        
        AudioComponentInstanceNew(inComp!, &audioOutUnit)
        
        // Configure audio unit for playback
        var flag : UInt32 = 1;
        
        // Enable speaker IO.
        AudioUnitSetProperty(audioOutUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             kAudioSystemOutputBus,
                             &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        // Set output format (the audio format that will be played by speaker).
        AudioUnitSetProperty(audioOutUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             kAudioSystemOutputBus,
                             &outAudioF,
                             UInt32(MemoryLayout.size(ofValue: outAudioF)))
        
        // Set input format (the audio format that will be fed into the unit).
        AudioUnitSetProperty(audioOutUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             kAudioSystemOutputBus,
                             &outAudioF,
                             UInt32(MemoryLayout.size(ofValue: outAudioF)))
        
        if useMic {
            // Enable mic IO.
            AudioUnitSetProperty(audioOutUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &flag,
                                 UInt32(MemoryLayout.size(ofValue: flag)))
            
            // Check if sample rates match (that's important)
            var preferredFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: preferredFormat))
            AudioUnitGetProperty(audioOutUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &preferredFormat,
                                 &size)
            
            print("Device audio format: \(preferredFormat) versus our \(inAudioF)")
            
            // TODO: We are assuming sample rates match
            if (preferredFormat.mSampleRate != inAudioF.mSampleRate) {
                print("SAmple rate mismatch!!!")
            }
            
            // Set input format (format of microphone output)
            AudioUnitSetProperty(audioOutUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &inAudioF,
                                 UInt32(MemoryLayout.size(ofValue: inAudioF)))
            
            // Set output format (the audio format we will receive).
            AudioUnitSetProperty(audioOutUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 kAudioSystemInputBus,
                                 &inAudioF,
                                 UInt32(MemoryLayout.size(ofValue: inAudioF)))
        }

        do {
            let ses = AVAudioSession.sharedInstance()
            try ses.setPreferredIOBufferDuration(TimeInterval(0.005))
            self.internalIOBufferDuration = ses.ioBufferDuration
        }
        catch {
            print("FAILED TO SET IO Duration")
        }
        
        print("Configured for internalIOBufersize=\(internalIOBufferDuration)")
        
        auhalPlayer.initUnit(unit: audioOutUnit, outFormat: outAudioF)
        auhalPlayer.addPlaybackCallback()
        if useMic {
            addRecordingCallback()
        }
        
        AudioUnitInitialize(audioOutUnit)
        AudioOutputUnitStart(audioOutUnit)
    }
    
    func addRecordingCallback() {
        // Allocate a single audioBuffer since we're dealing with mono-channel
        // input audio. Allocating buffers here once is more efficient.
        audioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        audioBuffer = AudioBuffer()
        audioBufferList[0] = audioBuffer
        audioBufferList[0].mData = nil
        audioBufferList[0].mDataByteSize = 0
        
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        callbackStruct.inputProc = {
             (inRefCon       : UnsafeMutableRawPointer,
              ioActionFlags  : UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp    : UnsafePointer<AudioTimeStamp>,
              inBusNumber    : UInt32,
              inNumberFrames : UInt32,
              ioData         : UnsafeMutablePointer<AudioBufferList>?) -> OSStatus in
            
            let _self = Unmanaged<ClientAUHALInterface>.fromOpaque(inRefCon).takeUnretainedValue()
            
            // Set audiobuffer to nil and compute buffer size. Note we only need
            // one buffer since we're taking in mono-channel virtual device.
            _self.audioBufferList[0].mData = nil
            _self.audioBufferList[0].mDataByteSize = inNumberFrames * _self.inAudioF.mBytesPerFrame
 
            // Request to fill audioBufferList.
            let res = AudioUnitRender(_self.audioOutUnit,
                                      ioActionFlags,
                                      inTimeStamp,
                                      inBusNumber,
                                      inNumberFrames,
                                      _self.audioBufferList.unsafeMutablePointer)
            _self.log("Rendered with status \(res) "
                    + "Got \(_self.audioBufferList.count) buffers "
                    + "of size \(_self.audioBufferList[0].mDataByteSize) "
                    + "and data \(_self.audioBufferList[0].mData)")
            
            // Ready to send buffers over to device.
            if _self.audioBufferList[0].mData != nil {
                _self.micPacketReady!(_self.audioBufferList[0].mData!, Int(_self.audioBufferList[0].mDataByteSize))
            }
            else {
                print("Failed to populate buffers!")
            }
            return .zero
        }
        
        AudioUnitSetProperty(audioOutUnit!,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Global,
                             kAudioSystemInputBus,
                             &callbackStruct,
                             UInt32(MemoryLayout.size(ofValue: callbackStruct)))
    }
}

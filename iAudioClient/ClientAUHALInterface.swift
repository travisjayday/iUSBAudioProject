//
//  MuxHalAudioPlayer.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/26/20.
//

import Foundation
import AVFoundation


// See http://atastypixel.com/blog/using-remoteio-audio-unit/ for an example.
class ClientAUHALInterface {

    var initted = false
    
    var remoteAudioUnit: AudioComponentInstance!
    var auhalPlayer: AUHALAudioPlayer!
    var auhalRecorder: AUHALAudioRecorder!
    var outAudioF: AudioStreamBasicDescription!
    
    var inAudioF: AudioStreamBasicDescription!
   
    var timeStart : Double = 0
    var bytesReceived : Int = 0
    var internalIOBufferDuration : Double = 0.0
    var debug = true
    var useMic = false

    /// Print wrapper.
    func log(_ s : String) {
        if debug { print("[ClientAUHALInterface] " + s) }
    }
    
    func endSession() {
        let speed = (Double(bytesReceived) / (Date().timeIntervalSince1970 - timeStart))
        print("SPEED: \(speed)bytes/s");
        AudioOutputUnitStop(remoteAudioUnit)
        AudioComponentInstanceDispose(remoteAudioUnit)
        initted = false
    }
    
    func initUnit(outFormat: AudioStreamBasicDescription, inFormat: AudioStreamBasicDescription?, _micPacketReady: ((_ ptr : UnsafeMutableRawPointer, _ len : Int) -> Void)?) {
        
        log("Initting mobile audio IO interface...")
        
        outAudioF = outFormat
        
        if initted { return }
        
        initted = true
        if inFormat != nil {
            log("inFormat is not nil, so will init recording Mic")
            log("inFormat: \(inFormat)")
            useMic = true
            inAudioF = inFormat
        }
        timeStart = Date().timeIntervalSince1970

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        
        var inComp = AudioComponentFindNext(nil, &desc)
        
        AudioComponentInstanceNew(inComp!, &remoteAudioUnit)
        
        // Configure audio unit for playback
        var flag : UInt32 = 1;
        
        // Enable speaker IO.
        AudioUnitSetProperty(remoteAudioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             kAudioSystemOutputBus,
                             &flag,
                             UInt32(MemoryLayout.size(ofValue: flag)))
        
        // Set output format (the audio format that will be played by speaker).
        AudioUnitSetProperty(remoteAudioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             kAudioSystemOutputBus,
                             &outAudioF,
                             UInt32(MemoryLayout.size(ofValue: outAudioF)))
        
        // Set input format (the audio format that will be fed into the unit).
        AudioUnitSetProperty(remoteAudioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             kAudioSystemOutputBus,
                             &outAudioF,
                             UInt32(MemoryLayout.size(ofValue: outAudioF)))
        
        if useMic {
            // Enable mic IO.
            AudioUnitSetProperty(remoteAudioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &flag,
                                 UInt32(MemoryLayout.size(ofValue: flag)))
            
            // Check if sample rates match (that's important)
            var preferredFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: preferredFormat))
            AudioUnitGetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &preferredFormat,
                                 &size)
            
            log("Device audio format: \(preferredFormat) versus our \(inAudioF)")
            
            // TODO: We are assuming sample rates match
            if (preferredFormat.mSampleRate != inAudioF.mSampleRate) {
               log("SAmple rate mismatch!!!")
            }
            
            // Set input format (format of microphone output)
            AudioUnitSetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &inAudioF,
                                 UInt32(MemoryLayout.size(ofValue: inAudioF)))
            
            // Set output format (the audio format we will receive).
            AudioUnitSetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 kAudioSystemInputBus,
                                 &inAudioF,
                                 UInt32(MemoryLayout.size(ofValue: inAudioF)))
        }

        do {
            let ses = AVAudioSession.sharedInstance()
            // NOTE: THIS PARAMETER IS SUPER IMPORTANT. Setting a low value
            // will make IO buffers small, so less latency in audio playback.
            // HOWEVER, making them too small, audio streaming won't be fast
            // enough and we'll get not enough new data available to fill these
            // buffers, so we'll get broken audio fragments.
            try ses.setPreferredIOBufferDuration(TimeInterval(0.01))
            self.internalIOBufferDuration = ses.ioBufferDuration
        }
        catch {
            log("FAILED TO SET IO Duration")
        }
        
        log("Configured for internalIOBufersize=\(internalIOBufferDuration)")
        
        auhalPlayer = AUHALAudioPlayer()
        auhalPlayer.initUnit(unit: remoteAudioUnit, outFormat: outAudioF)
        auhalPlayer.addPlaybackCallback()
        
        if useMic {
            auhalRecorder = AUHALAudioRecorder()
            auhalRecorder.initUnit(unit: remoteAudioUnit,
                                   inFormat: inFormat!,
                                   pcmPacketReady: _micPacketReady)
            auhalRecorder.addRecordingCallback()
        }
        
        AudioUnitInitialize(remoteAudioUnit)
        AudioOutputUnitStart(remoteAudioUnit)
    }
    
    
}

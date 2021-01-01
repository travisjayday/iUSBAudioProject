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
    var useMic = false
    
    let TAG = "ClientAUHALInterface"

    func endSession() {
        let speed = (Double(bytesReceived) / (Date().timeIntervalSince1970 - timeStart))
        Logger.log(.log, TAG, "SPEED: \(speed)bytes/s");
        Logger.log(.log, TAG, "Disposing of remoteIO Audio unit...")
        AudioOutputUnitStop(remoteAudioUnit)
        AudioComponentInstanceDispose(remoteAudioUnit)
        initted = false
    }
    
    func initUnit(outFormat: AudioStreamBasicDescription,
                  inFormat: AudioStreamBasicDescription?,
                  _micPacketReady: ((_ ptr : UnsafeMutableRawPointer, _ len : Int) -> Void)?)
    throws {
        
        Logger.log(.log, TAG, "Initting mobile audio IO interface...")
        
        outAudioF = outFormat
        
        if initted { return }
        
        initted = true
        if inFormat != nil {
            Logger.log(.log, TAG, "inFormat is not nil, so will init recording Mic")
            Logger.log(.log, TAG, "inFormat: \(inFormat)")
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
        Logger.log(.log, TAG, "Enabling speaker IO...")
        try handle(AudioUnitSetProperty(remoteAudioUnit,
                             kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output,
                             kAudioSystemOutputBus,
                             &flag,
                             UInt32(MemoryLayout.size(ofValue: flag))))
        
        // Set output format (the audio format that will be played by speaker).
        /*Logger.log(.log, TAG, "Setting speaker output format...")
        try handle(AudioUnitSetProperty(remoteAudioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output,
                             kAudioSystemOutputBus,
                             &outAudioF,
                             UInt32(MemoryLayout.size(ofValue: outAudioF))))*/
        
        // Set input format (the audio format that will be fed into the unit).
        Logger.log(.log, TAG, "Setting speaker's input format...")
        try handle(AudioUnitSetProperty(remoteAudioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             kAudioSystemOutputBus,
                             &outAudioF,
                             UInt32(MemoryLayout.size(ofValue: outAudioF))))
        
        if useMic {
            // Enable mic IO.
            Logger.log(.log, TAG, "Enabling IO on mic...")
            try handle(AudioUnitSetProperty(remoteAudioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &flag,
                                 UInt32(MemoryLayout.size(ofValue: flag))))
            
            // Check if sample rates match (that's important)
            var preferredFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: preferredFormat))
            try handle(AudioUnitGetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &preferredFormat,
                                 &size))
            
            Logger.log(.log, TAG, "Device audio format: \(preferredFormat) versus our \(inAudioF)")
            
            // TODO: We are assuming sample rates match
            if (preferredFormat.mSampleRate != inAudioF.mSampleRate) {
               Logger.log(.log, TAG, "SAmple rate mismatch!!!")
            }
            
            // Set input format (format of microphone output)
            Logger.log(.log, TAG, "Setting microphone's input format")
            /*try handle(AudioUnitSetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kAudioSystemInputBus,
                                 &inAudioF,
                                 UInt32(MemoryLayout.size(ofValue: inAudioF))))*/
            
            // Set output format (the audio format we will receive).
            Logger.log(.log, TAG, "Setting microphone's output format")
            try handle(AudioUnitSetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 kAudioSystemInputBus,
                                 &inAudioF,
                                 UInt32(MemoryLayout.size(ofValue: inAudioF))))
            
            try handle(AudioUnitGetProperty(remoteAudioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 kAudioSystemInputBus,
                                 &preferredFormat,
                                 &size))
            Logger.log(.log, TAG, "Resultnig stream format for mic is: \(preferredFormat)")
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
            Logger.log(.log, TAG, "FAILED TO SET IO Duration")
        }
        
        Logger.log(.log, TAG, "Configured for internalIOBufersize=\(internalIOBufferDuration)")
        
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
    
    /// Throws error if errorCode
    func handle(_ errorCode: OSStatus) throws {
        if errorCode == 0 { return }
        var s = "kAudioUnitErr_"
        switch errorCode {
        case kAudioUnitErr_Initialized:
            s += "Initialized"; break
        case kAudioUnitErr_InvalidProperty:
            s += "InvalidProperty"; break
        case kAudioUnitErr_FailedInitialization:
            s += "FailedInitialization"; break
        case kAudioUnitErr_InvalidScope:
            s += "InvalidScope"; break
        case kAudioUnitErr_InvalidElement:
            s += "InvalidElement"; break
        case kAudioUnitErr_InvalidParameter:
            s += "InvalidParameter"; break
        case kAudioUnitErr_CannotDoInCurrentContext:
            s += "CannotDoInCurrentContext"; break
        case kAudioUnitErr_InvalidPropertyValue:
            s += "InvalidPropertyValue"; break
        case kAudioUnitErr_InvalidParameter:
            s += "InvalidParameter"; break
        case kAudioUnitErr_PropertyNotWritable:
            s += "PropertyNotWritable"; break
        default:
            s += "Generic"
        }

        Logger.log(.emergency, TAG, "Error: \(s)!")
        throw NSError(domain: NSOSStatusErrorDomain,
                      code: Int(errorCode),
                      userInfo: [NSLocalizedDescriptionKey : "CAError: \(errorCode)" ])
    }
    
}

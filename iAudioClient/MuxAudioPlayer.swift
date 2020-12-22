//
//  MuxAudioPlayer.swift
//  iAudioServer
//
//  Created by Travis Ziegler on 12/20/20.
//

import Foundation
import AVFoundation

class MuxAudioPlayer {
    var audioQueue: AudioQueueRef!
    var initted = false
    
    var audioFormat: AudioStreamBasicDescription!
    
    var readyData : Data!
    var timestart : Double = 0
    var totalData : Double = 0
    let semaphore = DispatchSemaphore(value: 1)
    
    func playPacket(pcm: Data) {
        if !initted {
            initted = true
            readyData = Data()
            timestart = Date().timeIntervalSince1970
            initPlayFromHelloPacket()
        }
        
        semaphore.wait()
        if readyData.count < 2048 * 6 {
            readyData.append(pcm)
        }
        semaphore.signal()
        AudioQueueStart(audioQueue, nil)
        //print(readyData.count)

        /*
        totalData += Double(readyData.count)
        let t = Date().timeIntervalSince1970
        if (t - timestart > 10) {
            let speed = (totalData / (t - timestart)) / 1000000
            print("Need to support speed of \(speed) MB/sec")
        }*/
    }
    
    func audioQueueCallback(scopedSelf : MuxAudioPlayer,
                            inAQ : AudioQueueRef,
                            inBuffer : AudioQueueBufferRef) {
        semaphore.wait()
        print("Puffing audio")
        var chunkToPlay : Data!
        
        let aQBufSize : Int = Int(inBuffer.pointee.mAudioDataBytesCapacity)
        if aQBufSize < readyData.count {
            chunkToPlay = readyData.subdata(in: Range(readyData.startIndex...readyData.startIndex+aQBufSize))
            readyData.removeFirst(aQBufSize)
        }
        else if readyData.count > 1000 {
            chunkToPlay = readyData
            readyData.removeAll()
        }
        else {
            print("NOT ENOUGH DATA")
            //AudioQueuePause(inAQ)
            chunkToPlay = Data.init(count: aQBufSize)
        }
        
        chunkToPlay.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
            let rawPtr = UnsafeRawPointer(ptr)
            memcpy(inBuffer.pointee.mAudioData, rawPtr, chunkToPlay.count)
        }
        
        inBuffer.pointee.mAudioDataByteSize = UInt32(chunkToPlay.count)
        
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
        semaphore.signal()
    }

    func initPlayFromHelloPacket() {

        audioFormat = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
        
        AudioQueueNewOutput(
            &audioFormat,
            {
                (inUserData : UnsafeMutableRawPointer?,
                 inAQ : AudioQueueRef,
                 inBuffer : AudioQueueBufferRef) -> Void in
                    let scopedSelf = Unmanaged<MuxAudioPlayer>.fromOpaque(inUserData!).takeUnretainedValue()
                    scopedSelf.audioQueueCallback(
                        scopedSelf: scopedSelf,
                        inAQ: inAQ,
                        inBuffer: inBuffer)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &audioQueue)
        
        let bufferCap : UInt32 = 15320
        let numBufs = 4
        
        for _ in 0...4 {
            var buf : AudioQueueBufferRef!
            AudioQueueAllocateBuffer(audioQueue, bufferCap, &buf)
            buf.pointee.mAudioDataByteSize = bufferCap
            AudioQueueEnqueueBuffer(audioQueue, buf, 0, nil)
        }

        AudioQueueStart(audioQueue, nil)

    }
}

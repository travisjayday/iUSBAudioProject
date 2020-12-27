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
    let bufferCap : UInt32 = 7056
    
    var bytesReceived = 0
    var timeStart : Double = 0
    
    func stopPlaying() {
        let speed = (Double(bytesReceived) / (Date().timeIntervalSince1970 - timeStart))
        print("SPEED: \(speed *  1000 * 1000)MB/s");
        AudioQueueStop(audioQueue, true);
        AudioQueueDispose(audioQueue, true);
    }
    
    func playPacket(pcm: Data, format: AudioStreamBasicDescription) {
        if !initted {
            initted = true
            readyData = Data()
            timestart = Date().timeIntervalSince1970
            audioFormat = format
            initPlayFromHelloPacket()
            timeStart = Date().timeIntervalSince1970
        
        }
        
        semaphore.wait()
        if readyData.count < 352800 {
            readyData.append(pcm)
        }
        semaphore.signal()
        //AudioQueueStart(audioQueue, nil)
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
        
        print("Data available: \(readyData.count)")
        
        let aQBufSize : Int = Int(inBuffer.pointee.mAudioDataBytesCapacity)
        if aQBufSize <= readyData.count {
            chunkToPlay = readyData.subdata(in: Range(readyData.startIndex...readyData.startIndex+aQBufSize))
            readyData.removeFirst(aQBufSize)
        }
        /*else if readyData.count > 1000 {
            chunkToPlay = readyData
            readyData.removeAll()
        }*/
        else {
            print("NOT ENOUGH DATA")
            //AudioQueuePause(inAQ)
            chunkToPlay = Data.init(count: aQBufSize)
        }
        
        chunkToPlay.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
            let rawPtr = UnsafeRawPointer(ptr)
            memcpy(inBuffer.pointee.mAudioData, rawPtr, chunkToPlay.count)
        }
        semaphore.signal()
        
        inBuffer.pointee.mAudioDataByteSize = UInt32(chunkToPlay.count)
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)

    }
    

    func initPlayFromHelloPacket() {
        
        print("Starting audio queue with \(audioFormat)")

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
        
 
        let numBufs = 3
        
        for _ in 0...numBufs {
            var buf : AudioQueueBufferRef!
            AudioQueueAllocateBuffer(audioQueue, bufferCap, &buf)
            buf.pointee.mAudioDataByteSize = bufferCap
            AudioQueueEnqueueBuffer(audioQueue, buf, 0, nil)
        }

        AudioQueueStart(audioQueue, nil)

    }
}

//
//  PCMTransceiver.swift
//  iAudio CommonTools
//
//  Created by Travis Ziegler on 12/29/20.
//

import Foundation
import Socket
import AVFoundation

/// Abstraction for socket based communication of audio data. Handles basic
/// error correction, parses packet headers, calls appropriate callbacks. 
class PCMTransceiver {
    
    /// Called when a new PCM Audio packet comes in.
    var dataCallback: ((UnsafeMutablePointer<Int8>, Int) -> Void)!
    
    /// Called when a new connection start handshake comes in. First arg is
    /// The speaker output audio format requested by macOS, second arg is the
    /// microphone audio output format requested by macOS.
    var handshakeCallback: ((AudioStreamBasicDescription, AudioStreamBasicDescription?) -> Void)?
    
    /// Called when socket dies.
    var terminatedCallback: (() -> Void)!
    
    /// The socket.
    var sock : Socket
    
    /// Packet signatures and pre-allocated buffer.
    let kHeaderSig    = Data([0x69, 0x4, 0x20, 0])  // Header PCM Data Signature
    let kHandshakeSig = Data([0x69, 0x4, 0x19, 0])  // Header Handshak Signature
    let kHandMicSig   = Data([0x69, 0x4, 0x21, 0])  // Header Handshak With Mic Signature
    var packet        = Data(capacity: 2048)        // Preallocate Packet Buffer
    
    /// Debugging.
    let TAG = "PCMTransceiver"
    
    init(_ _sock : Socket,
         dataCallback: @escaping (UnsafeMutablePointer<Int8>, Int) -> Void,
         handshakeCallback: ((AudioStreamBasicDescription, AudioStreamBasicDescription?) -> Void)?,
         terminatedCallback: @escaping () -> Void) {
        self.dataCallback = dataCallback
        self.handshakeCallback = handshakeCallback
        self.terminatedCallback = terminatedCallback
        sock = _sock
    }
    
    func dataToASBD(data : NSData) -> AudioStreamBasicDescription {
        var restored = AudioStreamBasicDescription()
        let size = MemoryLayout.size(ofValue: restored)
        withUnsafeMutableBytes(of: &restored) {
            let d : UnsafeMutableRawPointer = $0.baseAddress!
            memcpy(d, data.bytes, size)
        }
        return restored
    }
    
    /// Called when audioStreamer queries current audio configuration and
    /// reports back the AudioStreamBasicDescription of the current stream.
    /// i.e. the format of future PCM Audio buffers, sample rate, etc.
    /// - Parameter absd: Serialized ASBD.
    /// - Throws: If connection to socket fails.
    func handshakePacketReady(absd : Data, useMic : Bool) throws {
        var len : UInt32 = UInt32(absd.count)
        packet.removeAll(keepingCapacity: true)
        if useMic { packet.append(kHandMicSig)   }
        else      { packet.append(kHandshakeSig) }  // append command sig
        packet.append(Data(bytes: &len, count: 4))  // append payload length
        packet.append(absd)                         // append payload
        Logger.log(.log, TAG, "Sending handshake \(packet[0]) \(packet[1]) \(packet[2])" +
            " \(packet[3]) \(packet[4]) \(packet[5])")
        Logger.log(.log, TAG, "Handshake size: \(packet.count). Embedded payload size: \(len)")
        try sock.write(from: packet)
    }
    
    /// Called when the AUHAL audio unit rendered a new buffer of PCM
    /// Audio data from Virtual USBAudioDriver (i.e. system output audio)
    /// - Parameters:
    ///   - pcmPtr: Pointer to the PCM Audio buffer.
    ///   - pcmLen: Length of the PCM Audio buffer
    func packetReady(_ pcmPtr : UnsafeMutableRawPointer, _ pcmLen : Int) {
        var len : UInt32 = UInt32(pcmLen)
        
        packet.removeAll(keepingCapacity: true)
        packet.append(kHeaderSig)
        packet.append(Data(bytes: &len, count: 4))
        packet.append(Data(bytesNoCopy: pcmPtr, count: pcmLen,
                           deallocator: Data.Deallocator.none))
        Logger.log(.verbose, TAG, "Sending packet with data \(packet[0]) \(packet[1]) \(packet[2])" +
            " \(packet[3]) \(packet[4]) \(packet[5])")
        do {
            try sock.write(from: packet)
        } catch {
            Logger.log(.emergency, TAG, "Failed to send packet")
            sock.close()
            terminatedCallback()
       }
    }
    
    /// Reads *exactly* n bytes from current sock into buffer.
    /// - Parameters:
    ///   - buffer: Destination buffer.
    ///   - count: Will ensure that this many bytes get read
    func readBytes(buffer : UnsafeMutablePointer<CChar>, count : Int) throws {
        var bytesRead = 0
        while bytesRead != count {
            bytesRead += try sock.read(into:
                            buffer.advanced(by: bytesRead),
                            bufSize: count - bytesRead,
                            truncate: true)
        }
    }
    
    /// Error correcting recieve loop. Calls appropritae callbacks on certain
    /// packets recevied (like audio packets, handshakes, etc).
    func receiveLoop() throws {
        var header: [Int8] = [Int8](repeating: 0, count: 8)
        var pcmBuf = Data(capacity: 2048)
        var errorCorrectedFlag = false
        while (true) {
            if (sock.remoteConnectionClosed) {
                terminatedCallback()
                return
            }
            if !errorCorrectedFlag {
                try readBytes(buffer: &header, count: 8)
            }
            else {
                errorCorrectedFlag = false
                try readBytes(buffer: &header + 2, count: 6)
            }
            
            Logger.log(.verbose, TAG, "Received header \(header[0]) \(header[1]) \(header[2]) \(header[3])" +
                " \(header[4]) \(header[5])")

            let payloadSize = Int(header.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            })
            
            Logger.log(.verbose, TAG, "Payload size \(payloadSize)")
            
            // we received a valid handshake packet
            if header[0] == 0x69 &&
                header[1] == 0x4 &&
                (header[2] == 0x19 || header[2] == 0x21) {
                
                var outAF : AudioStreamBasicDescription?
                var inAF: AudioStreamBasicDescription?
                
                if header[2] == 0x19 {
                    // handshake with mic disabled
                    var asbdBuf = Data.init(count: Int(payloadSize))
                    try asbdBuf.withUnsafeMutableBytes({
                        try readBytes(buffer: $0, count: payloadSize)
                    })
                    outAF = dataToASBD(data: asbdBuf as NSData)
                    inAF = nil
                }
                else {
                    var outAsbd = Data.init(count: Int(payloadSize / 2))
                    var inAsbd = Data.init(count: Int(payloadSize / 2))
                    try outAsbd.withUnsafeMutableBytes({
                        try readBytes(buffer: $0, count: payloadSize / 2)
                    })
                    try inAsbd.withUnsafeMutableBytes({
                        try readBytes(buffer: $0, count: payloadSize / 2)
                    })
                    outAF = dataToASBD(data: outAsbd as NSData)
                    inAF = dataToASBD(data: inAsbd as NSData)
                }
                Logger.log(.log, TAG, "Received handshake with audio format \(outAF) and \(inAF)")
                Logger.log(.log, TAG, "payload size was \(payloadSize)")
                if handshakeCallback != nil {
                    handshakeCallback!(outAF!, inAF)
                }
                Logger.log(.emergency, TAG, "ERROR HANDSHAKE CALLBACK NIL")
           }
            // we received a valid PCM packet signature
            else if header[0] == 0x69 && header[1] == 0x4 && header[2] == 0x20 {
                Logger.log(.verbose, TAG, "About to play PCM packety of size \(payloadSize)")
                pcmBuf.removeAll(keepingCapacity: true)
                pcmBuf.resetBytes(in: 0..<payloadSize)
                try pcmBuf.withUnsafeMutableBytes({(ptr : UnsafeMutableRawBufferPointer) in
                    let p = ptr.baseAddress!.assumingMemoryBound(to: Int8.self)
                    try readBytes(buffer: p, count: payloadSize)
                    dataCallback(p, payloadSize)
                })
             
            }
            // Error correction of wrong packet signature was detected.
            else {
                Logger.log(.emergency, TAG, "We've encountered misaligned communication. Attempting to "
                 + "autocorrect communication by stalling until next header")
                while true {
                    try readBytes(buffer: &header, count: 1)
                    if header[0] == 0x69 {
                        try readBytes(buffer: &header + 1, count: 1)
                        if header[1] == 0x4 {
                            break
                        }
                    }
                }
                errorCorrectedFlag = true
            }
        }
    }
}

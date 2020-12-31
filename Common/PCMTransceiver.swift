import Foundation
import Socket
import AVFoundation

class PCMTransceiver {
    
    public enum PCMPAK {
        case ServerHandshakeWithMic
        case ServerHandshake
        case PCMData
    }
    
    var dataCallback: ((UnsafeMutablePointer<Int8>, Int) -> Void)!
    var handshakeCallback: ((AudioStreamBasicDescription, AudioStreamBasicDescription?) -> Void)?
    var terminatedCallback: (() -> Void)!
    var sock : Socket
    let kHeaderSig    = Data([0x69, 0x4, 0x20, 0])  // Header PCM Data Signature
    let kHandshakeSig = Data([0x69, 0x4, 0x19, 0])  // Header Handshak Signature
    let kHandMicSig   = Data([0x69, 0x4, 0x21, 0])  // Header Handshak With Mic Signature
    var packet        = Data(capacity: 2048)        // Preallocate Packet Buffer
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
    func packetReady(pcmPtr : UnsafeMutableRawPointer, pcmLen : Int) {
        var len : UInt32 = UInt32(pcmLen)
        
        packet.removeAll(keepingCapacity: true)
        packet.append(kHeaderSig)
        packet.append(Data(bytes: &len, count: 4))
        packet.append(Data(bytesNoCopy: pcmPtr, count: pcmLen,
                           deallocator: Data.Deallocator.none))
        do {
            try sock.write(from: packet)
        } catch {
            Logger.log(.emergency, TAG, "Failed to send packet")
            sock.close()
            terminatedCallback()
       }
    }
    
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
                try sock.read(into: &header, bufSize: 8, truncate: true)
            }
            else {
                errorCorrectedFlag = false
                try sock.read(into: &header + 2, bufSize: 6, truncate: true)
            }
            
            Logger.log(.verbose, TAG, "Received header \(header[0]) \(header[1]) \(header[2]) \(header[3])" +
                " \(header[4]) \(header[5])")

            let payloadSize = Int(header.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            })
            
            Logger.log(.verbose, TAG, "Payload size \(payloadSize)")
            
            // we received a valid handshake packet
            if header[0] == 0x69 && header[1] == 0x4 && header[2] == 0x19 || header[2] == 0x21 {
                
                var outAF : AudioStreamBasicDescription?
                var inAF: AudioStreamBasicDescription?
                
                if header[2] == 0x19 {
                    // handshake with mic disabled
                    var asbdBuf = Data.init(count: Int(payloadSize))
                    try asbdBuf.withUnsafeMutableBytes({
                        try sock.read(into: $0, bufSize: payloadSize, truncate: true)
                    })
                    outAF = dataToASBD(data: asbdBuf as NSData)
                    inAF = nil
                }
                else {
                    var outAsbd = Data.init(count: Int(payloadSize / 2))
                    var inAsbd = Data.init(count: Int(payloadSize / 2))
                    try outAsbd.withUnsafeMutableBytes({
                        try sock.read(into: $0, bufSize: payloadSize / 2, truncate: true)
                    })
                    try inAsbd.withUnsafeMutableBytes({
                        try sock.read(into: $0, bufSize: payloadSize / 2, truncate: true)
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
                    try sock.read(into: p, bufSize: payloadSize, truncate: true)
                    dataCallback(p, payloadSize)
                })
             
            }
            else {
                Logger.log(.emergency, TAG, "We've encountered misaligned communication. Attempting to "
                 + "autocorrect communication by stalling until next header")
                while true {
                    try sock.read(into: &header, bufSize: 1, truncate: true)
                    if header[0] == 0x69 {
                        try sock.read(into: &header + 1, bufSize: 1, truncate: true)
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

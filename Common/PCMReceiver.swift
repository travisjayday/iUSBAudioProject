import Foundation
import Socket
import AVFoundation

class PCMReceiver {
    
    public enum PCMPAK {
        case ServerHandshakeWithMic
        case ServerHandshake
        case PCMData
    }
    
    var dataCallback: ((UnsafeMutablePointer<Int8>, Int) -> Void)!
    var handshakeCallback: ((AudioStreamBasicDescription, AudioStreamBasicDescription?) -> Void)?
    var sock : Socket
    var debug = true
    

    init(_ _sock : Socket,
         dataCallback: @escaping (UnsafeMutablePointer<Int8>, Int) -> Void,
         handshakeCallback: ((AudioStreamBasicDescription, AudioStreamBasicDescription?) -> Void)?) {
        self.dataCallback = dataCallback
        self.handshakeCallback = handshakeCallback
        sock = _sock
    }
    
    func log(_ s : String) {
        if debug { print("[iAudioClientApp]" + s) }
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
    
    func receive() throws {
        var header: [Int8] = [Int8](repeating: 0, count: 8)
        var pcmBuf = Data(capacity: 2048)
        var errorCorrectedFlag = false
        while (true) {
            if (sock.remoteConnectionClosed) { break; }
            if !errorCorrectedFlag {
                try sock.read(into: &header, bufSize: 8, truncate: true)
            }
            else {
                errorCorrectedFlag = false
                try sock.read(into: &header + 2, bufSize: 6, truncate: true)
            }
            
            log("Received header \(header[0]) \(header[1]) \(header[2]) \(header[3])" +
                " \(header[4]) \(header[5])")

            let payloadSize = Int(header.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            })
            
            log("Payload size \(payloadSize)")
            
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
                log("Received handshake with audio format \(outAF) and \(inAF)")
                log("payload size was \(payloadSize)")
                if handshakeCallback != nil {
                    handshakeCallback!(outAF!, inAF)
                }
                print("ERROR HANDSHAKE CALLBACK NIL")
           }
            // we received a valid PCM packet signature
            else if header[0] == 0x69 && header[1] == 0x4 && header[2] == 0x20 {
                log("About to play PCM packety of size \(payloadSize)")
                pcmBuf.removeAll(keepingCapacity: true)
                pcmBuf.resetBytes(in: 0..<payloadSize)
                try pcmBuf.withUnsafeMutableBytes({(ptr : UnsafeMutableRawBufferPointer) in
                    let p = ptr.baseAddress!.assumingMemoryBound(to: Int8.self)
                    try sock.read(into: p, bufSize: payloadSize, truncate: true)
                    dataCallback(p, payloadSize)
                })
             
            }
            else {
                log("We've encountered misaligned communication. Attempting to "
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

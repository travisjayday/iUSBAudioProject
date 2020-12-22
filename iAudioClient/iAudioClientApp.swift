//
//  iAudioClientApp.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/21/20.
//

import SwiftUI
import Socket

@main
struct iAudioClientApp: App {
    
    var client = ClientMain()
    
    var body: some Scene {
        WindowGroup {
            ContentView().onAppear(perform: {
                DispatchQueue.global(qos: .utility).async {
                    client.startListening()
                }
            })
        }
    }
}
    
class ClientMain  {
    var player : MuxAudioPlayer!
    
    func startListening() {
        do {
            let sock = try Socket.create(family: .inet, type: .stream, proto: .tcp)
            try sock.listen(on: 7000)
            try sock.acceptConnection()
            try sock.write(from: "Hello from iPad".data(using: .ascii)!)
            let buf = NSMutableData()
            try sock.read(into: buf)
            let s = String.init(data: buf as Data, encoding: .utf8)
            print("Receifved: \(s)")
            player = MuxAudioPlayer()
            let buffer = NSMutableData()
            while (true) {
                var rawHeader: [Int8] = [Int8](repeating: 0, count: 5)
                try sock.read(into: &rawHeader, bufSize: 5, truncate: true)
                print("Received header: \(rawHeader[0]), \(rawHeader[1])")
                let cmd = rawHeader[0]
                
                let header = rawHeader.map { UInt8(bitPattern: $0) }
                let payloadSize = UInt32(header[1]) | UInt32(header[2]) << 8 | UInt32(header[3]) << 16 | UInt32(header[4]) << 24
                
                if cmd == 0x41 {
                    print("Receiving PCM frame of size \(payloadSize)")
                    var pcmBuf = Data.init(count: Int(payloadSize))
                    try pcmBuf.withUnsafeMutableBytes({ (ptr) in
                        try sock.read(into: ptr, bufSize: Int(payloadSize), truncate: true)
                    })
                    player.playPacket(pcm: pcmBuf)
                }
            }
        } catch {
            print("FAIL")
        }
    }
}



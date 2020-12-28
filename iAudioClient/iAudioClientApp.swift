//
//  iAudioClientApp.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/21/20.
//

import SwiftUI
import Socket
import AVFoundation

@main
struct iAudioClientApp: App {
    
    @State var client : ClientMain!
    var contentView : ContentView = ContentView(appState: AppState())
    
    var body: some Scene {
        WindowGroup {
            contentView.onAppear(perform: {
                self.client = ClientMain(appState: contentView.appState)
                DispatchQueue.global(qos: .utility).async {
                    sleep(2)
                    client.startListening()
                }
            })
        }
    }
}
    
class ClientMain  {
    var player : MuxHALAudioPlayer!
    var sock : Socket!
    var appState : AppState!
    
    init(appState : AppState) {
        self.appState = appState
    }
    
    func dataToASBD(data : NSData) -> AudioStreamBasicDescription {
        var restored = AudioStreamBasicDescription()
        let size = MemoryLayout.size(ofValue: restored)
        withUnsafeMutableBytes(of: &restored) { (ptr: UnsafeMutableRawBufferPointer?) in
            let d : UnsafeMutableRawPointer = ptr!.baseAddress!
            memcpy(d, data.bytes, size)
        }
        print(restored)
        return restored
    }
    
    func startListening() {
        do {
            sock = try Socket.create(family: .inet, type: .stream, proto: .tcp)
            try sock.listen(on: 7000)
            try sock.acceptConnection()
            try sock.write(from: "Hello from iPad".data(using: .ascii)!)
            let buf = NSMutableData()
            try sock.read(into: buf)
            let s = String.init(data: buf as Data, encoding: .utf8)
            print("Receifved: \(s)")
            let buffer = NSMutableData()
            var currentAudioFormat : AudioStreamBasicDescription?
            while (true) {
                var rawHeader: [Int8] = [Int8](repeating: 0, count: 7)
                if (sock.remoteConnectionClosed) { break; }
                try sock.read(into: &rawHeader, bufSize: 7, truncate: true)
                print("Received header: \(rawHeader[0]), \(rawHeader[1])")
                let cmd = rawHeader[0]
                
                let header = rawHeader.map { UInt8(bitPattern: $0) }
                let payloadSize = UInt32(header[3])
                    | UInt32(header[4]) << 8
                    | UInt32(header[5]) << 16
                    | UInt32(header[6]) << 24
                
                // we received a valid handshake packet
                if rawHeader[0] == 0x69 && rawHeader[1] == 0x4 && rawHeader[2] == 0x19 {
                    var asbdBuf = Data.init(count: Int(payloadSize))
                    try asbdBuf.withUnsafeMutableBytes({ (ptr) in
                        try sock.read(into: ptr, bufSize: Int(payloadSize), truncate: true)
                    })
                    currentAudioFormat = dataToASBD(data: asbdBuf as NSData)
                    print("Received handshake with audio format \(currentAudioFormat)")
                    print("payload size was \(payloadSize) and resulting data ws \(asbdBuf.count)")
                    player = MuxHALAudioPlayer()
                }
                
                // we received a valid PCM packet signature
                if rawHeader[0] == 0x69 && rawHeader[1] == 0x4 && rawHeader[2] == 0x20 {
                    //print("Receiving PCM frame of size \(payloadSize)")
                    var pcmBuf = Data.init(count: Int(payloadSize))
                    try pcmBuf.withUnsafeMutableBytes({ (ptr) in
                        try sock.read(into: ptr, bufSize: Int(payloadSize), truncate: true)
                    })
                    player.playPacket(pcm: pcmBuf, format: currentAudioFormat!)
                }
            }
        } catch {
            print("FAIL")
        }
        player.stopPlaying()
        showAlert()
    }
    
    func showAlert() {
        DispatchQueue.main.async {
            self.appState.showAlert = true
        }
    }
}



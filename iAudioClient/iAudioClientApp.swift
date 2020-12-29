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
                    while (true) {
                        sleep(2)
                        do {
                            try client.startListening()
                        } catch {
                            print("Error when tried listening")
                        }
                    }
                }
            })
        }
    }
}
    
/// Class in charge of receiving and transmitting audio data 
class ClientMain  {
    
    /// The MuxHALAudioPlayer packets get piped into
    var player : MuxHALAudioPlayer!
    var sock : Socket!
    var appState : AppState!
    var debug = false
    var pcmBuf : Data!
    
    init(appState : AppState) {
        self.appState = appState
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
    
    func log(_ s : String) {
        if debug { print(s) }
    }
    
    func startListening() throws {
   
        sock = try Socket.create(family: .inet, type: .stream, proto: .tcp)
        try sock.listen(on: 7000)
        try sock.acceptConnection()
        try sock.write(from: "Hello from iPad".data(using: .ascii)!)
        let buf = NSMutableData()
        try sock.read(into: buf)
        let s = String.init(data: buf as Data, encoding: .utf8)
        print("Receifved: \(s)")
      
        var currentAudioFormat : AudioStreamBasicDescription?
        var header: [Int8] = [Int8](repeating: 0, count: 8)
        pcmBuf = Data(capacity: 2048)
        while (true) {
            if (sock.remoteConnectionClosed) { break; }
            try sock.read(into: &header, bufSize: 8, truncate: true)

            let payloadSize = Int(header.withUnsafeBytes {
                $0.load(fromByteOffset: 4, as: UInt32.self)
            })
            
            // we received a valid handshake packet
            if header[0] == 0x69 && header[1] == 0x4 && header[2] == 0x19 {
                var asbdBuf = Data.init(count: Int(payloadSize))
                try asbdBuf.withUnsafeMutableBytes({
                    try sock.read(into: $0, bufSize: payloadSize, truncate: true)
                })
                currentAudioFormat = dataToASBD(data: asbdBuf as NSData)
                log("Received handshake with audio format \(currentAudioFormat)")
                log("payload size was \(payloadSize) and resulting data ws \(asbdBuf.count)")
                player = MuxHALAudioPlayer()
            }
            
            // we received a valid PCM packet signature
            if header[0] == 0x69 && header[1] == 0x4 && header[2] == 0x20 {
                log("About to play PCM packety of size \(payloadSize)")
                pcmBuf.removeAll(keepingCapacity: true)
                pcmBuf.resetBytes(in: 0..<payloadSize)
                try pcmBuf.withUnsafeMutableBytes({
                    try sock.read(into: $0, bufSize: payloadSize, truncate: true)
                })
                log("about to enqueue packet")
                player.playPacket(pcm: pcmBuf, format: currentAudioFormat!)
            }
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



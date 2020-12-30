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
    
    func mainLoop() {
        while (true) {
            sleep(2)
            do {
                try client.startListening()
            } catch {
                print("Error when tried listening")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            contentView.onAppear(perform: {
                self.client = ClientMain(appState: contentView.appState)
                DispatchQueue.global(qos: .utility).async {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                        case .authorized: // The user has previously granted access to the camera.
                            mainLoop()
                        
                        case .notDetermined: // The user has not yet been asked for camera access.
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                if granted {
                                    mainLoop()
                                }
                            }
                        
                        case .denied: // The user has previously denied access.
                            return

                        case .restricted: // The user can't grant access due to restrictions.
                            return
                    }


                }
            })
        }
    }
}
    
/// Class in charge of receiving and transmitting audio data 
class ClientMain  {
    
    /// The MuxHALAudioPlayer packets get piped into
    var auhalIF : ClientAUHALInterface!
    var sock : Socket!
    var appState : AppState!
    var debug = false
    var pcmBuf : Data!
    var micPkt = Data(capacity: 2048)    // Preallocate Packet Buffer
    let kHeaderSig    = Data([0x69, 0x4, 0x20, 0]) // Header PCM Data Signature

    
    init(appState : AppState) {
        self.appState = appState
    }
    

    
    func log(_ s : String) {
        if debug { print("[iAudioClientApp]" + s) }
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
        
        func onReceived(bytes : UnsafeMutablePointer<Int8>, len : Int) {
            log("about to enqueue packet")
            auhalIF.auhalPlayer.enqueuePCM(bytes, len)
        }
        
        func onHandshake(outAF : AudioStreamBasicDescription,
                         inAF : AudioStreamBasicDescription?) {
            auhalIF = ClientAUHALInterface()
            auhalIF.initUnit(outFormat: outAF,
                             inFormat: inAF,
                             _micPacketReady: self.packetReady)
        }
        
        let rec = PCMReceiver(sock,
                              dataCallback: onReceived,
                              handshakeCallback: onHandshake)
        try rec.receive()
      
        auhalIF.endSession()
        showAlert()
    }
    
    /// Called when the AUHAL audio unit rendered a new buffer of PCM
    /// Audio data from Virtual USBAudioDriver (i.e. system output audio)
    /// - Parameters:
    ///   - pcmPtr: Pointer to the PCM Audio buffer.
    ///   - pcmLen: Length of the PCM Audio buffer
    func packetReady(pcmPtr : UnsafeMutableRawPointer, pcmLen : Int) {
        var len : UInt32 = UInt32(pcmLen)
        
        micPkt.removeAll(keepingCapacity: true)
        micPkt.append(kHeaderSig)
        micPkt.append(Data(bytes: &len, count: 4))
        micPkt.append(Data(bytesNoCopy: pcmPtr, count: pcmLen,
                           deallocator: Data.Deallocator.none))

        print("Mic Packet is ready to be sent")
        do {
            print("About to send \(micPkt[0]) \(micPkt[1]) \(micPkt[2]) " +
                    "\(micPkt[3]) \(micPkt[4]) \(micPkt[10]) \(micPkt[11])")
            try sock.write(from: micPkt)
        } catch {
            print("Failed to send packet")
            //player.endSession()
            //sock.close()
        }
    }
    
    func showAlert() {
        DispatchQueue.main.async {
            self.appState.showAlert = true
        }
    }
}



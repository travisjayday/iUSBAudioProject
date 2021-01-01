//
//  iAudioClientApp.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/21/20.
//

import SwiftUI
import Socket
import AVFoundation

/// Class that sets up UI for app and starts main client loop
@main
struct iAudioClientApp: App {
    
    @State var client : ClientMain!
    var contentView : ContentView = ContentView(appState: AppState())
    let TAG = "iAudioClientApp"
    
    /// Main app loop. Always try open port to listen on.
    func mainLoop() {
        while (true) {
            do {
                try client.startListening()
            } catch {
                Logger.log(.emergency, TAG, "Error when tried listening")
            }
            sleep(2)
        }
    }
    
    /// Create views and do mic permission check.
    var body: some Scene {
        WindowGroup {
            contentView.onAppear(perform: {
                self.client = ClientMain(appState: contentView.appState)
                DispatchQueue.global(qos: .utility).async {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                        case .authorized: // The user has previously granted access to the camera.
                            mainLoop()
                            break
                        case .notDetermined: // The user has not yet been asked for camera access.
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                if granted {
                                    mainLoop()
                                }
                            }
                            break
                        case .denied: // The user has previously denied access.
                            Logger.log(.emergency, TAG, "Microphnoe denied. Fatal.")
                            return
                        case .restricted: // The user can't grant access due to restrictions.
                            Logger.log(.emergency, TAG, "Microphnoe denied. Fatal.")
                            return
                    }
                }
            })
        }
    }
}
    
/// Class in charge of receiving and transmitting audio data.
class ClientMain  {
    
    /// The MuxHALAudioPlayer packets get piped into.
    var auhalIF : ClientAUHALInterface!
    
    /// The class that handles packet sending and receiving.
    var trans : PCMTransceiver!
    
    /// The usbmux socket.
    var sock : Socket!
    
    /// Handle for UI updates.
    var appState : AppState!
    
    /// Logging.
    let TAG = "ClientMain"
    
    /// Enables time domain microphone maginitude visualization.
    let viz = true
    
    /// Class for abstracting visualization updates.
    var audioViz : AudioViz!

    init(appState : AppState) {
        self.appState = appState
        let numDots = self.appState.dots.count
        audioViz = AudioViz(appState, numDots)
    }

    /// Main event body. Blocks unitl an inbound connection comes in. Then
    /// sets up audio streaming.
    func startListening() throws {
   
        sock = try Socket.create(family: .inet, type: .stream, proto: .tcp)
        try sock.setReadTimeout(value: 3)
        try sock.setWriteTimeout(value: 3)
        try sock.listen(on: 7000)
        try sock.acceptConnection()
        
        // We got a new connection. Say hello.
        try sock.write(from: "Hello from iPad".data(using: .ascii)!)
        let buf = NSMutableData()
        try sock.read(into: buf)
        let s = String.init(data: buf as Data, encoding: .utf8)
        Logger.log(.log, TAG, "Receifved: \(s)")
        
        /// Called when server sends a handshake consisting of audio format desc.
        func onHandshake(outAF : AudioStreamBasicDescription,
                         inAF  : AudioStreamBasicDescription?) {
            auhalIF = ClientAUHALInterface()
            do {
                try auhalIF.initUnit(outFormat: outAF, inFormat: inAF, _micPacketReady: onSend)
            } catch {
                print("Fata l error")
            }
        }
        
        /// Called when a new packet of microphone data becomes ready.
        /// Do visualization and send it to the transceiver
        func onSend(pcmPtr : UnsafeMutableRawPointer, pcmLen : Int) {
            let ptr = pcmPtr.bindMemory(to: Int16.self, capacity: pcmLen)
            audioViz.onNewBuffer(ptr: UnsafeBufferPointer<Int16>.init(start: ptr, count: pcmLen / 2))
            trans.packetReady(pcmPtr, pcmLen)
        }
        
        /// Called when a new audio packet came in from the mac system.
        /// Play it on our speaker.
        func onReceived(bytes : UnsafeMutablePointer<Int8>, len : Int) {
            Logger.log(.verbose, TAG, "about to enqueue packet")
            auhalIF.auhalPlayer.enqueuePCM(bytes, len)
        }
        
        /// Called when the socket breaks.
        func onTerminated() {
            auhalIF.endSession()
            showAlert()
        }
        
        /// Set up callbacks and start listening for incoming packets
        trans = PCMTransceiver(sock, dataCallback:       onReceived,
                                     handshakeCallback:  onHandshake,
                                     terminatedCallback: onTerminated)
        try trans.receiveLoop()
    }
    
    func showAlert() {
        DispatchQueue.main.async {
            self.appState.showAlert = true
        }
    }
}



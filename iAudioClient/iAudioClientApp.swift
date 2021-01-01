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
    let TAG = "iAudioClientApp"
    
    func mainLoop() {
        while (true) {
            sleep(2)
            do {
                try client.startListening()
            } catch {
                Logger.log(.emergency, TAG, "Error when tried listening")
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
    var trans : PCMTransceiver!
    var sock : Socket!
    var appState : AppState!
    let TAG = "ClientMain"
    let viz = true
    var audioViz : AudioViz!

    init(appState : AppState) {
        self.appState = appState
        let numDots = self.appState.dots.count
        audioViz = AudioViz(appState, numDots)
    }

    func startListening() throws {
   
        sock = try Socket.create(family: .inet, type: .stream, proto: .tcp)
        try sock.setReadTimeout(value: 3)
        try sock.setWriteTimeout(value: 3)
        try sock.listen(on: 7000)
        try sock.acceptConnection()
        try sock.write(from: "Hello from iPad".data(using: .ascii)!)
        let buf = NSMutableData()
        try sock.read(into: buf)
        let s = String.init(data: buf as Data, encoding: .utf8)
        Logger.log(.log, TAG, "Receifved: \(s)")
        
        func onHandshake(outAF : AudioStreamBasicDescription,
                         inAF  : AudioStreamBasicDescription?) {
            auhalIF = ClientAUHALInterface()
            do {
                try auhalIF.initUnit(outFormat: outAF, inFormat: inAF, _micPacketReady: onSend)
            } catch {
                print("Fata l error")
            }
        }
        
        func onSend(pcmPtr : UnsafeMutableRawPointer, pcmLen : Int) {
            let ptr = pcmPtr.bindMemory(to: Int16.self, capacity: pcmLen)
            audioViz.onNewBuffer(ptr: UnsafeBufferPointer<Int16>.init(start: ptr, count: pcmLen / 2))
            trans.packetReady(pcmPtr, pcmLen)
        }
        
        func onReceived(bytes : UnsafeMutablePointer<Int8>, len : Int) {
            Logger.log(.verbose, TAG, "about to enqueue packet")
            auhalIF.auhalPlayer.enqueuePCM(bytes, len)
        }
        
        func onTerminated() {
            auhalIF.endSession()
            showAlert()
        }
        
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



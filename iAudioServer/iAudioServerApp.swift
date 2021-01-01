//
//  iAudioServerApp.swift
//  iAudioServer
//
//  Created by Travis Ziegler on 12/17/20.
//

import Cocoa
import SwiftUI
import Socket
import AVFoundation


/// Desired behavior:
///     - App is running in menu bar: No devices connected
///     - User connects device.
///     - Case 1: User has client app open on device
///         - Client app realizes it has been connected to PC. Opens port.
///         - Server app realizees device has been connected.
///             Tries to connect to port for 5 seconds.
///         - Success -> Activate audio re-transmission
///         - Failure -> Device shows as in-active and request user to reconnect
///     - Case 2: User does not have app on device
///         - Server app realizes device has been connected.
///             Tries to connect ot port for 5 seconds.
///         - Failure -> Device shows as in-active and request user to reconnect
@main
struct iAudioServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings{
            EmptyView()
        }
    }
}
class AppDelegate: NSObject, NSApplicationDelegate {

    var popover: NSPopover!
    var statusBarItem: NSStatusItem!
    var contentView: ContentView!
    var muxHandler: USBMuxHandler!
    var audioStreamer: MuxHALAudioStreamer!
    var useMic : Bool = true
    let TAG = "ServerAppDelegate"
    
    func tryConnectToDeviceLoop() {
        DispatchQueue.global(qos: .utility).async {
            var succ = false
            while true {
                succ = self.muxHandler.tryConnectToDevice()
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {

        // Get reference to SwiftUI view.
        contentView = ContentView();
        
        // Create class to interface with USB mutliplexer usbmuxd
        muxHandler = USBMuxHandler(_serverState: self.contentView.serverState,
                                   _connectedCallback: deviceConnected)
        
        // Try to connect to devices always.
        tryConnectToDeviceLoop()

        // Create popover UI in menu bar
        popover = NSPopover();
        popover.contentSize = NSSize(width: 400, height: 400);
        popover.behavior = .transient;
        popover.contentViewController =
            NSHostingController(rootView: self.contentView);

        self.statusBarItem = NSStatusBar.system.statusItem(
            withLength: CGFloat(NSStatusItem.variableLength))
        
        // Button click action to open popup on click
        if let button = self.statusBarItem.button {
            button.image = NSImage(named: "Icon");
            button.action = #selector(togglePopover(_:));
            button.target = self;
        }
    }
    
    /// Called when the menu button is clicked. Shows the popup.
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = self.statusBarItem.button {
            if self.popover.isShown {
                self.popover.performClose(sender)
            } else {
                self.popover.show(relativeTo: button.bounds,
                                  of: button,
                                  preferredEdge: NSRectEdge.maxY)
            }
        }
    }
    
    /// Called when a remote connection to an instance of iAudioClient App
    /// has been established.
    /// - Parameter sock: The socket that directly connects to the device.
    func deviceConnected(_ sock: Socket) throws -> Void{
        
        try sock.setReadTimeout(value: 3)
        try sock.setWriteTimeout(value: 3)
        
        func onReceived(bytes : UnsafeMutablePointer<Int8>, len : Int) {
            Logger.log(.verbose, TAG, "about to enqueue IOS MIC packet")
            if contentView.serverState.enableMicDistort {
                bytes.withMemoryRebound(to: Int16.self, capacity: len) { (ptr : UnsafeMutablePointer<Int16>) in
                    let bufptr = UnsafeMutableBufferPointer<Int16>.init(start: ptr, count: len / 2)
                    var arr = Array(repeating: 0.0, count: len / 2)
                    for i in 0..<arr.count {
                        arr[i] = Double(Int(bufptr[i]))
                    }
                    let fft = FFT()
                    let res = fft.calculate(arr, fps: 48000)
                    for i in 0..<res.count {
                        let j = max(min(Int(res[i]), Int(Int16.max)), Int(Int16.min))
                        bufptr[i] = Int16(j)
                    }
                    audioStreamer.micAuhal.enqueuePCM(bytes, len)
                }
            }
            else {
                audioStreamer.micAuhal.enqueuePCM(bytes, len)
            }
        }
        
        func onTerminated() {
            Logger.log(.log, TAG, "Terminating audio streamer...")
            audioStreamer.endSession()
        }
        
        Logger.log(.log, TAG, "Creating PCM transceiver...")
        let trans = PCMTransceiver(
            sock,
            dataCallback: onReceived,
            handshakeCallback: nil,
            terminatedCallback: onTerminated)
        
        // Create class to interface with system audio output
        Logger.log(.log, TAG, "Configuring audio devices...")
        audioStreamer = MuxHALAudioStreamer()
                
        /// Start audio streaming session
        try audioStreamer.makeSession(
            _packetReady: trans.packetReady,
            _handshakePacketReady: trans.handshakePacketReady,
            _useMic: useMic)

        Logger.log(.log, TAG, "Entering receive loop...")
        try trans.receiveLoop()
    }
}

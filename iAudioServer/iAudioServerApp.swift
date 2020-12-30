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
    
    func tryConnectToDeviceLoop() {
        DispatchQueue.global(qos: .utility).async {
            var succ = false
            while !succ {
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
        
        // Create class to interface with system audio output
        audioStreamer     = MuxHALAudioStreamer()
        
        let kHeaderSig    = Data([0x69, 0x4, 0x20, 0]) // Header PCM Data Signature
        let kHandshakeSig = Data([0x69, 0x4, 0x19, 0]) // Header Handshak Signature
        let kHandMicSig   = Data([0x69, 0x4, 0x21, 0]) // Header Handshak Signature
        var packet        = Data(capacity: 2048)    // Preallocate Packet Buffer
        
        /// Called when audioStreamer queries current audio configuration and
        /// reports back the AudioStreamBasicDescription of the current stream.
        /// i.e. the format of future PCM Audio buffers, sample rate, etc.
        /// - Parameter absd: Serialized ASBD.
        /// - Throws: If connection to socket fails.
        func handshakePacketReady(absd : Data) throws {
            var len : UInt32 = UInt32(absd.count)
            packet.removeAll(keepingCapacity: true)
            if useMic { packet.append(kHandMicSig)   }
            else      { packet.append(kHandshakeSig) }  // append command sig
            packet.append(Data(bytes: &len, count: 4))  // append payload length
            packet.append(absd)                         // append payload
            print("Sending handshake \(packet[0]) \(packet[1]) \(packet[2])" +
                " \(packet[3]) \(packet[4]) \(packet[5])")
            print("Handshake size: \(packet.count). Embedded payload size: \(len)")
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
            //print("Sending packet \(packet[0]) \(packet[1]) \(packet[2])" +
                //" \(packet[3]) \(packet[4]) \(packet[5])")
            //print("Packet size: \(packet.count). Embedded payload size: \(len)")
            do {
                try sock.write(from: packet)
            } catch {
                print("Failed to send packet")
                audioStreamer.endSession()
                sock.close()
                tryConnectToDeviceLoop()
            }
        }

        /// Start audio streaming session
        try audioStreamer.makeSession(
            _packetReady: packetReady,
            _handshakePacketReady: handshakePacketReady,
            _useMic: useMic)
        
        func onReceived(bytes : UnsafeMutablePointer<Int8>, len : Int) {
            print("about to enqueue IOS MIC packet")
            audioStreamer.micAuhal.enqueuePCM(bytes, len)
        }
        
        let rec = PCMReceiver(sock, dataCallback: onReceived, handshakeCallback: nil)
        try rec.receive()
    }
}

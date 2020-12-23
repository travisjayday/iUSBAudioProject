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

/*
 Desired behavior:
    - App is running in menu bar: No devices connected
    - User connects device.
        - Case 1: User has client app open on device
            - Client app realizes it has been connected to PC. Opens port.
            - Server app realizees device has been connected. Tries to connect to port for 5 seconds.
            - Success -> Activate audio re-transmission
            - Failure -> Device shows as in-active and request user to re-connect
        - Case 2: User does not have app on device
            - Server app realizes device has been connected. Tries to connect ot port for 5 seconds.
            - Failure -> Device shows as in-active and request user to re-connect
 */

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
    var audioStreamer: MuxAudioStreamer!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        func packetReaddd(data: Data) {}
        do {
            try MuxAudioStreamer().makeSession(_packetReady: packetReaddd)
        }
        catch {
            print("Failed to start audio stream")
        }
        self.contentView = ContentView();
        
        func connected(sock: Socket) {
            audioStreamer = MuxAudioStreamer()
            func packetRead(data : Data) {
                var cmd : UInt8 = 0x41
                let cmdD = Data(bytes: &cmd, count: 1)
                var len : UInt32 = UInt32(data.count)
                let lenD = Data(bytes: &len, count: 4)
                let d = NSMutableData()
                d.append(cmdD)
                d.append(lenD)
                d.append(data)
                do {
                    try sock.write(from: d)
                    print("Sent \(d.count)")
                } catch {
                    print("Failed to send packet")
                    audioStreamer.endSession()
                    sock.close()
                    DispatchQueue.global(qos: .utility).async {
                        self.muxHandler.tryConnectToDevice()
                    }
                }
            }
            func handshakePacketReady(packet : Data) {
                
            }
            do {
                try audioStreamer.makeSession(_packetReady: packetRead,
                                              _gotAudioFormat: handshakePacketReady)
            }
            catch {
                print("Failed to start audio stream")
            }
        }
        
        muxHandler = USBMuxHandler(_serverState: self.contentView.serverState,
                                   _connectedCallback: connected)
        
        DispatchQueue.global(qos: .utility).async {
            while true {
                self.muxHandler.tryConnectToDevice()
            }
        }

        print("Hello, world")
        let popover = NSPopover();
        popover.contentSize = NSSize(width: 400, height: 400);
        popover.behavior = .transient;
        popover.contentViewController = NSHostingController(rootView: self.contentView);
        self.popover = popover;
        
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        if let button = self.statusBarItem.button {
            button.image = NSImage(named: "Icon");
            button.action = #selector(togglePopover(_:));
            button.target = self;
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        print("IT's poppin")
        if let button = self.statusBarItem.button {
            if self.popover.isShown {
                self.popover.performClose(sender)
            } else {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.maxY)
            }
        }
    }
}

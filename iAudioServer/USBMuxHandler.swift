import Cocoa
import Socket

/// Takes charge of communicating with usbmuxd daemon to poll
/// and try to connect to attached iOS devices over USB.
class USBMuxHandler: NSObject {
    
    /// Encodable template struct used to generate PLIST messages to send
    /// to usbmuxd. See https://github.com/libimobiledevice
    /// for actual struct layout used by usbmuxd
    struct MuxPacket : Codable {
        var ClientVersionString : String = "libusbmuxd 2.0.2"
        var ProgName            : String = "iUSBAudio"
        var MessageType         : String = "None"
        var kLibUSBMuxVersion   :    Int = 3
        var PortNumber          :  Int16 = 0
        var DeviceID            :  UInt8 = 0
        
        init(_ messageType : String) {
            self.MessageType = messageType
        }
        
        init(_ messageType : String, _ portNumber : Int16, _ deviceID : UInt8) {
            self.MessageType = messageType
            self.PortNumber  = portNumber.bigEndian
            self.DeviceID    = deviceID
        }
        
        /// Given a ConnectionStruct, build valid usbmuxd comprehensible packet.
        /// - Returns: Data packet ready to be sent over socket
        func serialize() throws -> Data {
            // encode plist as xml data
            let enc = PropertyListEncoder()
            enc.outputFormat = .xml
            let xmlPlist = try enc.encode(self)

            // The remaining bytes of the usbmuxd header.
            // Here we specify protocol version 1 and message type  8 (PLIST).
            let headerBytes : [UInt8] = [1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0]

            // Get size of packet to prepend to above header bytes and receive
            // valid header.
            let size = Int32(xmlPlist.count) + Int32(headerBytes.count) + 4
            let sizeBytes = withUnsafeBytes(of: size.littleEndian, Array.init)

            return sizeBytes + headerBytes + xmlPlist
        }
    }
    
    /// Size of usbmux header.
    let kUSBMuxHeaderSize = 16

    /// Connected to swift UI. Chaning this state updates UI.
    var serverState: ServerState!
    
    /// Called when connection to a device is established
    var connectedCallback: (Socket) throws -> Void
    
    /// Register callbacks.
    init(_serverState: ServerState,
         _connectedCallback: @escaping (_ dev : Socket) throws -> Void) {
        connectedCallback = _connectedCallback
        serverState = _serverState
    }
    
    /// Awaits a reponse from usbmux socket. Parses header and reads response
    /// into a plist which it returns as a dictionary. Function is blocking.
    func awaitResponsePlist(sock: Socket) throws -> [String : Any] {
        
        // read resulting header
        var header = [Int8](repeating: 0, count: kUSBMuxHeaderSize)
        try sock.read(into: &header, bufSize: kUSBMuxHeaderSize, truncate: true)
        
        // extract packet size from header (packet size=4st 4 bytes).
        let packetSize = header.withUnsafeBytes { $0.load(as: UInt32.self) }

        // read remaining payload into memory
        let payloadSize = Int(packetSize) - kUSBMuxHeaderSize
        var rawPayload = [Int8](repeating: 0, count: payloadSize)
        try sock.read(into: &rawPayload, bufSize: payloadSize, truncate: true)
        let payloadData = NSData(bytes: rawPayload, length: payloadSize)
        
        // parse payload as plist and cast to dict
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        return try PropertyListSerialization.propertyList(
            from: payloadData as Data, format: &fmt) as! [String : Any]
    }
    
    /// Sends command represented by MuxPacket to usbmuxd
    /// and returns response as a dictionary parsed from plist
    func sendCmd(_ sock: Socket, _ cmd: MuxPacket) throws -> [String : Any] {
        // send command and await response
        try sock.write(from: cmd.serialize())
        return try awaitResponsePlist(sock: sock)
    }
    
    /// Tries to connect to a device by given ID over sock. If succesfull,
    /// will call connected callback. Return True of success, else false
    func connectDeviceById(_ sock: Socket, _ devId : UInt8) throws -> Bool {
        // try to connect to device's running app
        let resp = try sendCmd(sock, MuxPacket("Connect", 7000, devId))
                                
        if (resp["Number"] as! Int == 0) {
            // connection succesful. Exchange hellos.
            updateStatus(status: .connected_active)
            print("connected success")
            let data = NSMutableData()
            try sock.read(into: data)
            let s = String.init(data: data as Data, encoding: .utf8)
            print("Received: \(s)")
            try sock.write(from: "Hello from computer".data(using: .utf8)!)
            try connectedCallback(sock)
            return true;
        }
        else {
            updateStatus(status: .connected_inactive)
            print("Failed to connect")
            return false;
        }
    }
    
    /// Update the GUI status on main thread
    func updateStatus(status: ServerStatus) {
        DispatchQueue.main.async {
            self.serverState.status = status
        }
    }
    
    /// Tries to connect to an iOS device.
    /// If a device is connected,
    ///     will check if it's active or not (app running).
    ///         If it is, start trasmission.
    ///         Else show error.
    /// If no device is connected,
    ///     will block until device connected, check if it's active or not.
    ///     Try to connect.
    func tryConnectToDevice() -> Bool {
        var succ = false
        print("Starting tryToConnectToDevice()")
        
        // Update UI to show we're trying to connect.
        updateStatus(status: .trying_to_connect)
        
        do {
            // Create socket.
            print("Trying to connect to usbmuxd")
            let sock = try Socket.create(family: .unix,
                                         type: .stream,
                                         proto: .unix)
            sock.readBufferSize = 32768
            try sock.connect(to: "/var/run/usbmuxd")

            // List currently connected devices.
            let plist = try sendCmd(sock, MuxPacket("ListDevices"))
            let devices = plist["DeviceList"] as! NSArray

            // For each device in the list
            for case let dev as [String : Any] in devices {
                
                let devId = dev["DeviceID"] as! UInt8
                
                print("Device found #\(devId)")
                
                do {
                    let connected = try connectDeviceById(sock, devId)
                    if connected {
                        succ = true
                    }
                }
                catch {
                    updateStatus(status: .connected_inactive)
                }
            }
            
            print("No device connected. start listening");
            
            // No device were connected.
            if serverState.status != .connected_active {
                
                try sendCmd(sock, MuxPacket("Listen"))
                
                // While we don't have a connected device,
                while serverState.status != .connected_active {
                    
                    // block until we have new info from listening socket and
                    // start listening for new plug-in events.

                    // This plist is either connection or disconnection response
                    let plist = try awaitResponsePlist(sock: sock)
                    
                    let devId = plist["DeviceID"] as! UInt8
    
                    if plist["MessageType"] as! String == "Attached" {
                        updateStatus(status: .trying_to_connect)
                        print("Attached device")
                        
                        // sets status to either connected_active
                        // or connected_inactive
                        
                        let plist = try sendCmd(sock, MuxPacket("ListDevices"))
                        let devices = plist["DeviceList"] as! NSArray
                        print(devices)

                        let connected = try connectDeviceById(sock, devId)
                        
                        if !connected {
                            sock.close()
                            sleep(5)
                        }
                        else {
                            succ = true
                        }
                    }
                    else if plist["MessageType"] as! String == "Detached" {
                        print("Device detached")
                        updateStatus(status: .no_devs_found)
                    }
                }
            }
        } catch {
            print("error: \(error)")
        }
        print("Finished tryConnectToDevice()")
        return succ
    }
}

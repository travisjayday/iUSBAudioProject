import Cocoa
import Socket
 
class USBMuxHandler: NSObject {
    var magic : [UInt8]!
    let USBMUX_HEADER_SIZE = 16
    let XML_HEAD =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n<dict>\n"
    let XML_TAIL = "</dict>\n</plist>\n"
    let XML_LIST_DEVICES =
        "\t<key>ClientVersionString</key>\n" +
            "\t<string>libusbmuxd 2.0.2</string>\n" +
        "\t<key>MessageType</key>\n" +
            "\t<string>ListDevices</string>\n" +
        "\t<key>ProgName</key>\n" +
            "\t<string>dotnet</string>\n" +
        "\t<key>kLibUSBMuxVersion</key>\n" +
            "\t<integer>3</integer>\n"
    let XML_CONNECT =
        "\t<key>ClientVersionString</key>\n" +
            "\t<string>libusbmuxd 2.0.2</string>\n" +
        "\t<key>MessageType</key>\n" +
            "\t<string>Connect</string>\n" +
        "\t<key>ProgName</key>\n" +
            "\t<string>dotnet</string>\n" +
        "\t<key>kLibUSBMuxVersion</key>\n" +
            "\t<integer>3</integer>\n"
    let XML_LISTEN =
        "\t<key>ClientVersionString</key>\n" +
            "\t<string>libusbmuxd 2.0.2</string>\n" +
        "\t<key>MessageType</key>\n" +
            "\t<string>Listen</string>\n" +
        "\t<key>ProgName</key>\n" +
            "\t<string>dotnet</string>\n" +
        "\t<key>kLibUSBMuxVersion</key>\n" +
            "\t<integer>3</integer>\n"
    var XML_PLIST_FMT =  PropertyListSerialization.PropertyListFormat.xml
    var serverState: ServerState!
    var connectedCallback: ((Socket) -> Void)?
    
    init(_serverState: ServerState, _connectedCallback: @escaping (_ dev : Socket) -> Void) {
        connectedCallback = _connectedCallback
        print("Constructed")
        serverState = _serverState
    }

    func cmdListDevices() -> Data {
        let msg = XML_HEAD + XML_LIST_DEVICES + XML_TAIL
        let size : Int32 = Int32(msg.count) + Int32(magic.count) + 4
        let sizeBytes = withUnsafeBytes(of: size.littleEndian, Array.init)
        let header = sizeBytes + magic
        return header + msg.data(using: .utf8)!
    }
    
    func cmdListen() -> Data {
        let msg = XML_HEAD + XML_LISTEN + XML_TAIL
        let size : Int32 = Int32(msg.count) + Int32(magic.count) + 4
        let sizeBytes = withUnsafeBytes(of: size.littleEndian, Array.init)
        let header = sizeBytes + magic
        return header + msg.data(using: .utf8)!
    }
    
    func cmdConnect(deviceId : UInt8, port : Int16) -> Data {
        print("Genned conn request for device \(deviceId):\(port)")
        let msg = XML_HEAD + XML_CONNECT +
            "\t<key>DeviceID</key>\n" +
                "\t<integer>\(deviceId)</integer>\n" +
            "\t<key>PortNumber</key>\n" +
                "\t<integer>\(port.bigEndian)</integer>\n" +
            XML_TAIL;
        let size : Int32 = Int32(msg.count) + Int32(magic.count) + 4
        let sizeBytes = withUnsafeBytes(of: size.littleEndian, Array.init)
        let header = sizeBytes + magic
        return header + msg.data(using: .utf8)!
    }
    
    /**
     Awaits a reponse from usbmux socket. Parses header and reads response into
     a plist which it returns as a dictionary. Function is blocking.
     */
    func awaitResponsePlist(sock: Socket) throws -> [String : Any] {
        
        // read resulting header
        var rawHeader: [Int8] = [Int8](repeating: 0, count: USBMUX_HEADER_SIZE)
        try sock.read(into: &rawHeader, bufSize: USBMUX_HEADER_SIZE, truncate: true)
        
        // extract packet size from header
        let header = rawHeader.map { UInt8(bitPattern: $0) }
        let packetSize = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        
        // read remaining payload into memory
        var rawPayload: [Int8] = [Int8](repeating: 0, count: Int(packetSize) - USBMUX_HEADER_SIZE)
        try sock.read(into: &rawPayload, bufSize: Int(packetSize) - USBMUX_HEADER_SIZE, truncate: true)
        
        // parse payload as plist
        let resp = Data(rawPayload.map { UInt8(bitPattern: $0) })
        let plist = try PropertyListSerialization.propertyList(from: resp as Data, format: &XML_PLIST_FMT) as! [String : Any]
        
        return plist
    }
    
    /**
     Sends command to usbmuxd and returns response as a plist
        cmd: serialized PLIST with usbmuxdheader
     */
    func sendCmd(sock: Socket, cmd: Data) throws -> [String : Any] {
        // send command and await response
        try sock.write(from: cmd)
        return try awaitResponsePlist(sock: sock)
    }
    
    /**
     Tries to connect to a device by given ID over sock. If succesfull, will call
     startAudioTransmission. Return True of success, else false
     */
    func connectDeviceById(sock: Socket, devId : UInt8) throws -> Bool {
        // try to connect to device's running app
        let resp = try sendCmd(sock: sock, cmd: cmdConnect(deviceId: devId, port: 7000))
        
        print(resp)
        
        if (resp["Number"] as! Int == 0) {
            // connection succesful
            updateStatus(status: .connected_active)
            print("connected success")
            let data = NSMutableData()
            try sock.read(into: data)
            let s = String.init(data: data as Data, encoding: .utf8)
            print("Received: \(s)")
            try sock.write(from: "Hello from computer".data(using: .utf8)!)
            connectedCallback!(sock)
            return true;
        }
        else {
            updateStatus(status: .connected_inactive)
            print("Failed to connect")
            return false;
        }
    }
    
    /**
     Update the GUI status on main thread
     */
    func updateStatus(status: ServerStatus) {
        DispatchQueue.main.async {
            self.serverState.status = status
        }
    }
    
    /**
     Tries to connect to an iOS device.
     If a device is connected, will check if it's active or not (app running). If it is, start trasmission. Else show error.
     If no device is connected, will block until device connected, check if it's active
     or not. Try to connect.
     */
    func tryConnectToDevice() {
        print("Starting tryToConnectToDevice()")
        
        // init magic array for sending header
        magic = [UInt8](repeating: 0x0, count: 12)
        magic[0] = 1
        magic[4] = 8
        
        // update UI to show we're trying to connect
        updateStatus(status: .trying_to_connect)
        
        do {
            
            // create socket
            print("Trying to connect to usbmuxd")
            let sock = try Socket.create(family: .unix, type: .stream, proto: .unix)
            sock.readBufferSize = 32768
            try sock.connect(to: "/var/run/usbmuxd")

            // list currently connected devices
            let plist = try sendCmd(sock: sock, cmd: cmdListDevices())
            let devices = plist["DeviceList"] as! NSArray

            // for each device in the list
            for case let dev as [String : Any] in devices {
                
                let devId = dev["DeviceID"] as! UInt8
                
                print("Device found #\(devId)")
                
                let connected = try connectDeviceById(sock: sock, devId: devId)
                if (connected) {
                    while (true) {}
                }
            }
            
            print("No device connected. start listening");
            
            // no device were connected
            if serverState.status != .connected_active {
                
                try sendCmd(sock: sock, cmd: cmdListen())
                
                // while we don't have a connected device,
                while serverState.status != .connected_active {
                    
                    // block until we have new info from listening socket
                    // start listening for new plug-in events

                    // this plist is either connection or disconnection response
                    let plist = try awaitResponsePlist(sock: sock)
                    
                    print(plist)
                    
                    let devId = plist["DeviceID"] as! UInt8
    
                    if plist["MessageType"] as! String == "Attached" {
                        updateStatus(status: .trying_to_connect)
                        print("Attached device")
                        // sets status to either connected_active or connected_inactive
                        
                        let plist = try sendCmd(sock: sock, cmd: cmdListDevices())
                        let devices = plist["DeviceList"] as! NSArray
                        print(devices)

                        let connected = try connectDeviceById(sock: sock, devId: devId)
                        
                        if !connected {
                            sock.close()
                            sleep(5)
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
    }
}

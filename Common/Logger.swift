import Foundation

enum DebugLevel : Int {
    case none       = 3
    case emergency  = 2
    case log        = 1
    case verbose    = 0
}

class Logger {

    static let symLevel = Array(["V", "L", "E", " "])
    static let debugLevel : DebugLevel = .log
    
    /// Print wrapper.
    static func log(_ lvl : DebugLevel, _ tag : String, _ s : String) {
        if lvl.rawValue >= debugLevel.rawValue {
            print("[\(symLevel[lvl.rawValue])][\(tag)]: " + s)
        }
    }
}

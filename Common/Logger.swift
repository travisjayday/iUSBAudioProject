//
//  Logger.swift
//  iAudio CommonTools
//
//  Created by Travis Ziegler on 12/29/20.
//

import Foundation

enum DebugLevel : Int {
    case none       = 3     // Don't print anything.
    case emergency  = 2     // Only print error messages.
    case log        = 1     // Only print set-up / one time messages.
    case verbose    = 0     // Print ALL messages (in every callback).
}

/// Class used for managing logs. Set Logger.debugLevel to determine what
/// messages to print to console. 
class Logger {

    static let symLevel = Array(["V", "L", "E", " "])
    
    /// The current debug level.
    static let debugLevel : DebugLevel = .log
    
    /// Print wrapper.
    static func log(_ lvl : DebugLevel, _ tag : String, _ s : String) {
        if lvl.rawValue >= debugLevel.rawValue {
            print("[\(symLevel[lvl.rawValue])][\(tag)]: " + s)
        }
    }
}

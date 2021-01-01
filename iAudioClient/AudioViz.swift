//
//  AudioViz.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/31/20.
//

import Foundation

class AudioViz {
    
    var numDots : Int!
    var appState : AppState!
    var sampleRate = 1    // pick a dot after every n samples
    var sampleIndex = 0
    var bufferIdx = 0
    var firstPacket = true
    var ignoreVal : Int16 = 0
    var buffer : [Double]!

    init(_ appState : AppState, _ numDots : Int) {
        self.appState = appState
        self.numDots = numDots
        buffer = Array(repeating: 0, count: self.numDots)
    }
    
    func onNewBuffer(ptr : UnsafeBufferPointer<Int16>) {
        while sampleIndex < ptr.count {
            let val = Double(Int(ptr[sampleIndex])) / Double(Int(Int16.max))
            buffer[bufferIdx] = val
            bufferIdx += 1
            if bufferIdx == buffer.count {
                bufferIdx = 0
                updateUI()
            }
            sampleIndex += sampleRate
        }
        sampleIndex -= ptr.count
    }
    
    func updateUI() {
        var arr = Array(repeating: Point(0), count: numDots)
        for i in 0..<arr.count {
            arr[i].value = buffer[i]
        }
        DispatchQueue.main.async {
            self.appState.dots = arr
        }
    }

}

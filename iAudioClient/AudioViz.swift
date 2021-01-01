//
//  AudioViz.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/31/20.
//

import Foundation

/// Class that modifies the state of the points array in ContentView.swift to
/// enable visualization of time domain audio waveforms.
class AudioViz {
    
    /// Determined by UI.
    var numDots : Int!
    
    /// Connection to UI.
    var appState : AppState!
    
    /// Consider every sample.
    var sampleRate = 1
    
    var sampleIndex = 0
    var bufferIdx = 0
    var firstPacket = true
    
    /// Temporary buffer to avoid memory leaks.
    var buffer : [Double]!

    init(_ appState : AppState, _ numDots : Int) {
        self.appState = appState
        self.numDots = numDots
        buffer = Array(repeating: 0, count: self.numDots)
    }
    
    func onNewBuffer(ptr : UnsafeBufferPointer<Int16>) {
        while sampleIndex < ptr.count {
            // Swift is weird...
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
    
    /// Creates array of points that will update UI on main thread. 
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

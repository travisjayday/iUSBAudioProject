//
//  ContentView.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/21/20.
//

import SwiftUI

class AppState : ObservableObject {
    @Published var showAlert = false
    @Published var dots : [Point] = []
    
    init() {
        for i in 0...1024 {
            dots.append(Point(sin(Double(i) / 5)))
        }
    }
}

struct Point: Identifiable {
    var id = UUID()
    var value : Double = 0.0

    init(_ val : Double) {
        value = val
    }
}

struct ContentView: View {
    @ObservedObject var appState : AppState
    let max = 65536
    let min = 0
    
    var body: some View {
        GeometryReader { geo in
        ZStack {
            Button(action: {
                self.appState.showAlert.toggle()
            }) {
                Text("Show Alert")
            }
            .alert(isPresented: self.$appState.showAlert) {
                Alert(title: Text("Hello"))
            }
            ForEach(0..<appState.dots.count, id:\.self) {
                i in
                let vpp = CGFloat(geo.size.width / CGFloat(appState.dots.count))
                let val = CGFloat(appState.dots[i].value)
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .position(x: vpp * CGFloat(i),
                              y: geo.size.height * (-val / 2 + 0.5))
            }
        }.drawingGroup()
            
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView(appState: AppState())
            //ContentView(appState: AppState())
        }
    }
}

//
//  ContentView.swift
//  iAudioClient
//
//  Created by Travis Ziegler on 12/21/20.
//

import SwiftUI

class AppState : ObservableObject {
    @Published var showAlert = false
}

struct Point: Identifiable {
    var id = UUID()

}

struct ContentView: View {
    @ObservedObject var appState : AppState
   // var dots : [Int16] = Array([Point()])
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
            //ForEach(dots) { i in
            Circle()
                .fill(Color.red)
                .frame(width: 20, height: 20)
                .position(x: /*@START_MENU_TOKEN@*/10.0/*@END_MENU_TOKEN@*/, y: /*@START_MENU_TOKEN@*/10.0/*@END_MENU_TOKEN@*/)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView(appState: AppState())
            ContentView(appState: AppState())
        }
    }
}

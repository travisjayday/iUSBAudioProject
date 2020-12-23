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

struct ContentView: View {
    @ObservedObject var appState : AppState
    var body: some View {
        Button(action: {
            self.appState.showAlert.toggle()
        }) {
            Text("Show Alert")
        }
        .alert(isPresented: self.$appState.showAlert) {
            Alert(title: Text("Hello"))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(appState: AppState())
    }
}

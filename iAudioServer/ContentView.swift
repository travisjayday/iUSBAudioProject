//
//  ContentView.swift
//  iAudioServer
//
//  Created by Travis Ziegler on 12/17/20.
//

import SwiftUI

enum ServerStatus {
    case looking_for_devs
    case no_devs_found
    case trying_to_connect
    case connected_inactive
    case connected_active
}

class ServerState: ObservableObject {
    @Published var status = ServerStatus.connected_inactive;
    @Published var numDevices = 0;
    @Published var enableMicDistort = false;
}

struct ContentView: View {
    @ObservedObject var serverState = ServerState();

    func genStatus() -> some View {
        var statusViews : [Any] = [];
        var statusText = "";
        var isBuffering = false;
        
        switch serverState.status {
        case .looking_for_devs:
            statusText = "Looking for USB devices...";
            isBuffering = true;
            break;
        case .no_devs_found:
            statusText = "No connected devices";
            break;
        case .trying_to_connect:
            statusText = "Trying to connect..."
            isBuffering = true;
        case .connected_inactive:
            statusText = "Connection failed.\n\nPlease launch the iAudio app on your device and re-connect it."
            break;
        case .connected_active:
            statusText = "Audio connection active"
        }
        statusViews.append(Text(statusText)
                            .opacity(0.4)
                            .fixedSize(horizontal: false, vertical: /*@START_MENU_TOKEN@*/true/*@END_MENU_TOKEN@*/)
                            .frame(maxWidth:.infinity, alignment: .leading));
        
        if isBuffering {
            statusViews.append(
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.5)
                    .frame(width: 20, height: 20)
                    .padding(.horizontal, 1)
            )
        }
        
        return HStack {
            ForEach(0..<statusViews.count, id:\.self) {
                idx in AnyView(_fromValue: statusViews[idx])
            }
        }
    }
    
    func toggleMic() {
        serverState.enableMicDistort.toggle()
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                Text("iAudioServer").font(.title2)
                    .frame(maxWidth: .infinity, alignment: .topLeading);
                Button(action: {
                    
                },
                label: {
                    Image(systemName: "questionmark")
                })
                .cornerRadius(10).frame(width: 20, height: 20).clipShape(/*@START_MENU_TOKEN@*/Circle()/*@END_MENU_TOKEN@*/)
            }
            Divider();
            genStatus();
            Divider();
            
            Toggle(isOn: $serverState.enableMicDistort, label: {
                Text("iOS Microphone FFT")
            })

        }
        .frame(width: 200.0).padding(15)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

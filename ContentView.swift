import SwiftUI
import SpriteKit

@main
struct WobbleWheelsApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var lan = LAN()
    @State private var scene: GameScene?
    @State private var multi = false

    var body: some View {
        ZStack {
            Color(red: 0.53, green: 0.81, blue: 0.92).ignoresSafeArea()
            if let scene {
                SpriteView(scene: scene).ignoresSafeArea()
                VStack {
                    Button { quit() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.black.opacity(0.6))
                    }
                    .padding(.top, 8)
                    Spacer()
                }
            } else {
                menu
            }
        }
        .onReceive(lan.$connected) { connected in
            if connected && scene == nil {
                start(multi: true)
            } else if !connected && multi && scene != nil {
                quit()          // opponent left
            }
        }
    }

    private var menu: some View {
        VStack(spacing: 14) {
            Text("WOBBLE WHEELS")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
            switch lan.mode {
            case .idle:
                Button("Solo") { start(multi: false) }
                Button("Host LAN game") { lan.host() }
                Button("Join LAN game") { lan.join() }
            case .hosting:
                ProgressView()
                Text("Waiting for player 2…")
                Button("Cancel") { lan.stop() }
            case .joining:
                Text(lan.hosts.isEmpty ? "Looking for hosts…" : "Tap a host to join:")
                ForEach(lan.hosts, id: \.self) { h in
                    Button(h.displayName) { lan.invite(h) }
                }
                Button("Cancel") { lan.stop() }
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func start(multi: Bool) {
        let s = GameScene(size: CGSize(width: 900, height: 420))
        s.scaleMode = .aspectFill
        s.lan = multi ? lan : nil
        self.multi = multi
        UIApplication.shared.isIdleTimerDisabled = true
        scene = s
    }

    private func quit() {
        multi = false
        scene = nil
        lan.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

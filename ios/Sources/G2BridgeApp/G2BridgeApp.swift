// g2-bridge iOS app entry point.
//
// Owns the single G2Connection (the BLE link to the glasses) and the
// BridgeServer (the local HTTP endpoint). Both live for the app's lifetime.

import SwiftUI

@main
struct G2BridgeApp: App {
    @StateObject private var g2 = G2Connection()
    @State private var server: BridgeServer?

    var body: some Scene {
        WindowGroup {
            ContentView(g2: g2, startServer: startServerIfNeeded)
                .onAppear { startServerIfNeeded() }
        }
    }

    /// Lazily create + start the HTTP server once (idempotent). Deferred to first
    /// appearance so the listener binds after the app is foregrounded.
    private func startServerIfNeeded() {
        if server == nil {
            let s = BridgeServer(g2: g2, port: 8080)
            s.start()
            server = s
        }
    }
}

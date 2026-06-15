// The single-screen bridge UI:
//   • Connect / Disconnect button bound to G2Connection.status
//   • Live status + detail text
//   • The HTTP address to hit (http://<wifi-ip>:8080)
//   • A TextField + Send to push a test line straight to the lens
//
// Keep it one screen, clean. The HTTP server is owned by the app; this view only
// drives the BLE connection and shows where to POST.

import SwiftUI

struct ContentView: View {
    @ObservedObject var g2: G2Connection
    /// Called to (re)start the HTTP server - wired from the app so the address
    /// section can offer a retry if the listener didn't come up.
    var startServer: () -> Void

    @State private var testLine: String = "hello from g2-bridge"
    @State private var wifiIP: String = NetworkInfo.wifiIPv4() ?? "-"

    private var serverURL: String { "http://\(wifiIP):8080" }

    private var isConnected: Bool { g2.status == .ready }
    private var isBusy: Bool {
        g2.status == .scanning || g2.status == .connecting || g2.status == .authenticating
    }

    var body: some View {
        NavigationStack {
            Form {
                // ---- connection ------------------------------------------
                Section("Glasses") {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(g2.status.rawValue.capitalized)
                            .font(.headline)
                        Spacer()
                        if isBusy { ProgressView() }
                    }
                    if !g2.detail.isEmpty {
                        Text(g2.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(action: toggleConnection) {
                        Text(connectButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isBusy)
                    .buttonStyle(.borderedProminent)
                }

                // ---- HTTP endpoint ---------------------------------------
                Section("Local HTTP endpoint") {
                    LabeledContent("Address") {
                        Text(serverURL).font(.system(.body, design: .monospaced))
                    }
                    Text("POST /text  {\"text\":\"…\"}\nPOST /image  (raw PNG/JPEG)\nGET  /status")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Refresh IP / restart server") {
                        wifiIP = NetworkInfo.wifiIPv4() ?? "-"
                        startServer()
                    }
                }

                // ---- test push -------------------------------------------
                Section("Send a test line") {
                    TextField("Text to display", text: $testLine, axis: .vertical)
                        .lineLimit(1...4)
                    Button("Send to lens") {
                        let line = testLine
                        Task { @MainActor in await g2.displayText(line) }
                    }
                    .disabled(!isConnected)
                }
            }
            .navigationTitle("g2-bridge")
        }
    }

    private var connectButtonTitle: String {
        switch g2.status {
        case .ready:                       return "Disconnect"
        case .scanning:                    return "Scanning…"
        case .connecting:                  return "Connecting…"
        case .authenticating:              return "Authenticating…"
        default:                           return "Connect"
        }
    }

    private var statusColor: Color {
        switch g2.status {
        case .ready:         return .green
        case .error:         return .red
        case .disconnected:  return .gray
        default:             return .orange
        }
    }

    private func toggleConnection() {
        if isConnected {
            g2.disconnect()
        } else {
            g2.connect()   // works from .disconnected and .error
        }
    }
}

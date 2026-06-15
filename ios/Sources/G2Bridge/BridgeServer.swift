// BridgeServer - a tiny, dependency-free local HTTP/1.1 server (Network.framework)
// that turns the iPhone into a network endpoint for the G2 glasses. Anything on
// the LAN can POST text/images and they render on the lens.
//
//   POST /text    {"text":"..."}      → G2Connection.displayText  (teleprompter)
//   POST /image   raw PNG/JPEG body   → fit into 576×288 gray → displayComponent
//   GET  /status                      → {"status":"...","detail":"..."}
//   GET  /                            → one-line help string
//
// DESIGN / LIMITS (intentional - this is a personal bridge, not a web server):
//   • HTTP/1.1, but every response sets `Connection: close` and the socket is
//     closed after one request/response. No keep-alive, no pipelining.
//   • The full request (headers + body) is buffered in memory before dispatch.
//     A `maxBody` cap (4 MB) guards against a runaway upload; bodies over the cap
//     get a 413. Fine for a PNG screenshot; do not point a file upload at it.
//   • Only the request line, Content-Length, and Content-Type headers are parsed.
//     Chunked transfer-encoding is NOT supported (send a Content-Length). Most
//     clients (`curl`, URLSession with Data body) send Content-Length, so this is
//     fine in practice.
//   • No TLS, no auth. Bind it to a trusted LAN only. (iOS Local Network
//     permission is the only gate - see the README.)

import Foundation
import Network
import CoreGraphics
import ImageIO       // CGImageSource* (PNG/JPEG decode)
#if canImport(UIKit)
import UIKit
#endif

final class BridgeServer {

    private let port: NWEndpoint.Port
    private let g2: G2Connection
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "g2bridge.http")
    private let maxBody = 4 * 1024 * 1024   // 4 MB hard cap on a single request body

    /// Published-ish state for the UI (read on the main thread after `start`).
    private(set) var isRunning = false
    private(set) var lastError: String?

    init(g2: G2Connection, port: UInt16 = 8080) {
        self.g2 = g2
        self.port = NWEndpoint.Port(rawValue: port) ?? 8080
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.log("listening on :\(self.port.rawValue)")
                case .failed(let err):
                    self.isRunning = false
                    self.lastError = err.localizedDescription
                    self.log("listener failed: \(err.localizedDescription)")
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = error.localizedDescription
            log("start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func log(_ m: String) { print("[HTTP] \(m)") }

    // ---- connection handling ------------------------------------------------
    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until we have full headers + (Content-Length) body, then
    /// dispatch. One request per connection.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.log("recv error: \(error.localizedDescription)")
                conn.cancel(); return
            }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            // Need the header terminator before we can decide what to do.
            guard let headerEnd = self.rangeOfHeaderEnd(buf) else {
                if buf.count > self.maxBody {
                    self.respond(conn, status: 413, contentType: "text/plain", body: Data("body too large\n".utf8))
                    return
                }
                if isComplete { conn.cancel(); return }
                self.receive(conn, buffer: buf); return
            }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            let bodyStart = headerEnd.upperBound
            guard let request = self.parseRequest(headerData) else {
                self.respond(conn, status: 400, contentType: "text/plain", body: Data("bad request\n".utf8))
                return
            }

            let have = buf.count - bodyStart
            let need = request.contentLength
            if need > self.maxBody {
                self.respond(conn, status: 413, contentType: "text/plain", body: Data("body too large\n".utf8))
                return
            }
            if have < need {
                if isComplete { conn.cancel(); return }   // client hung up mid-body
                self.receive(conn, buffer: buf); return    // keep reading the body
            }

            let body = buf.subdata(in: bodyStart..<(bodyStart + need))
            self.handle(conn, request: request, body: body)
        }
    }

    /// Find the CRLFCRLF that ends the header block.
    private func rangeOfHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])   // \r\n\r\n
        return data.range(of: sep)
    }

    private struct Request {
        let method: String
        let path: String
        let contentLength: Int
        let contentType: String
    }

    private func parseRequest(_ header: Data) -> Request? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        // Strip any query string for routing.
        let rawPath = parts[1]
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var contentLength = 0
        var contentType = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { contentLength = Int(value) ?? 0 }
            else if key == "content-type" { contentType = value.lowercased() }
        }
        return Request(method: method, path: path, contentLength: contentLength, contentType: contentType)
    }

    // ---- routing ------------------------------------------------------------
    private func handle(_ conn: NWConnection, request: Request, body: Data) {
        log("\(request.method) \(request.path) (\(body.count)B)")
        switch (request.method, request.path) {
        case ("GET", "/"):
            let help = "g2-bridge\n" +
                       "POST /text  {\"text\":\"...\"}\n" +
                       "POST /image  (raw PNG/JPEG body)\n" +
                       "GET  /status\n"
            respond(conn, status: 200, contentType: "text/plain", body: Data(help.utf8))

        case ("GET", "/status"):
            // G2Connection state is @Published on the main actor - read it there.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let status = self.g2.status.rawValue
                let detail = self.g2.detail
                let json = "{\"status\":\"\(self.jsonEscape(status))\",\"detail\":\"\(self.jsonEscape(detail))\"}"
                self.respond(conn, status: 200, contentType: "application/json", body: Data(json.utf8))
            }

        case ("POST", "/text"):
            guard let text = parseTextBody(body) else {
                respond(conn, status: 400, contentType: "text/plain", body: Data("expected {\"text\":\"...\"}\n".utf8))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.g2.displayText(text)
                self.respond(conn, status: 200, contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            }

        case ("POST", "/image"):
            guard !body.isEmpty else {
                respond(conn, status: 400, contentType: "text/plain", body: Data("empty image body\n".utf8))
                return
            }
            guard let cg = Self.decodeImage(body) else {
                respond(conn, status: 415, contentType: "text/plain", body: Data("could not decode image (PNG/JPEG only)\n".utf8))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.g2.displayComponent { ctx in
                    Self.drawFitted(cg, into: ctx, canvasW: 576, canvasH: 288)
                }
                self.respond(conn, status: 200, contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            }

        default:
            respond(conn, status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
        }
    }

    // ---- body decoding ------------------------------------------------------
    /// Accept `{"text":"..."}` JSON, or a bare/`text/plain` body as a fallback.
    private func parseTextBody(_ body: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let text = obj["text"] as? String {
            return text
        }
        // Fallback: treat the whole body as plain text if it's not empty JSON noise.
        if let s = String(data: body, encoding: .utf8), !s.isEmpty,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return s
        }
        return nil
    }

    /// Decode PNG/JPEG bytes into a CGImage. Uses UIImage when available (handles
    /// orientation), else a CGImageSource.
    static func decodeImage(_ data: Data) -> CGImage? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) {
            return ui.cgImage ?? cgImageViaSource(data)
        }
        #endif
        return cgImageViaSource(data)
    }

    private static func cgImageViaSource(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Draw `image` into the canvas (already a y-up gray context filled black,
    /// white = bright) fit/letterboxed, preserving aspect ratio and centred.
    /// Mirrors EvenHub.bmp4's expectation: brighter source pixels → brighter lens.
    static func drawFitted(_ image: CGImage, into ctx: CGContext, canvasW: Int, canvasH: Int) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let cw = CGFloat(canvasW), ch = CGFloat(canvasH)
        let scale = min(cw / iw, ch / ih)
        let dw = iw * scale, dh = ih * scale
        let ox = (cw - dw) / 2, oy = (ch - dh) / 2
        // The EvenHub render context is y-up (CGContext default), so CGImage draws
        // in natural orientation here.
        ctx.draw(image, in: CGRect(x: ox, y: oy, width: dw, height: dh))
    }

    // ---- response helper ----------------------------------------------------
    private func respond(_ conn: NWConnection, status: Int, contentType: String, body: Data) {
        let reason = Self.reasonPhrase(status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func jsonEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        default:  return "Status"
        }
    }
}

// ---- Wi-Fi IP helper --------------------------------------------------------
enum NetworkInfo {
    /// Best-effort IPv4 address of the active Wi-Fi interface (`en0`), so the UI
    /// can show `http://<ip>:8080`. Returns nil if not on Wi-Fi.
    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let interface = p.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {   // Wi-Fi on iOS
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
            ptr = interface.ifa_next
        }
        return address
    }
}

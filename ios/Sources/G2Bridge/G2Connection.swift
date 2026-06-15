// Even Realities G2 dual-arm connection manager (CoreBluetooth).
//
// Ported from a verified-working reference implementation. See PROTOCOL.md.
// The mic / LC3 audio stream path is intentionally REMOVED for the g2-bridge v1
// (optional per the spec); everything else - dual-arm connect, the 7-packet auth,
// the 1.5 s heartbeat, sendBoth 18/12 ms pacing, BLE flow control via
// canSendWriteWithoutResponse, EvenHub priming, image tile streaming with the
// sliding ack window, and the native text/list container paths - is kept verbatim.
//
// The glasses are TWO separate BLE peripherals (left + right arm), each exposing
// the Nordic UART Service. Text only renders when sent to BOTH arms, so this
// manager scans for both, connects both, and mirrors text writes to each arm
// (left first, then right). EvenHub traffic (native containers, images) goes to
// the RIGHT ARM ONLY.

import Foundation
import Combine
import CoreBluetooth
import CoreGraphics

enum G2Status: String {
    case disconnected, scanning, connecting, authenticating, ready, error
}

final class G2Connection: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published private(set) var status: G2Status = .disconnected
    @Published private(set) var detail: String = ""

    /// Native container event callbacks (optional - a bridge can ignore taps).
    /// onListTap(containerName, rowIndex, itemName) - CLICK on a list row.
    var onListTap: ((String, Int, String) -> Void)?
    /// onTextTap(containerName) - CLICK on a text container.
    var onTextTap: ((String) -> Void)?
    /// onPageEvent(containerName, osEventType) - scroll / foreground / exit etc.
    var onPageEvent: ((String, Int) -> Void)?
    /// onDoubleTap() - a physical double-tap on the glasses (SYS event type 3).
    var onDoubleTap: (() -> Void)?

    // ---- per-arm state ------------------------------------------------------
    private final class Arm {
        let side: String                 // "L" or "R"
        var peripheral: CBPeripheral?
        var write: CBCharacteristic?     // control/teleprompter write (…2E5401)
        var displayWrite: CBCharacteristic?  // binary image/render channel (…2E6401)
        var notify: CBCharacteristic?
        var ready = false                // characteristics discovered + notify on
        var servicesTotal = 0            // GATT enumeration progress
        var servicesDone = 0
        init(_ s: String) { side = s }
    }
    private let left  = Arm("L")
    private let right = Arm("R")
    private var arms: [Arm] { [left, right] }

    private var central: CBCentralManager?
    private var heartbeatTask: Task<Void, Never>?
    private var displayRefreshTask: Task<Void, Never>?
    private var lastText: String?
    private var userDisconnected = false
    private var scanTimeout: DispatchWorkItem?
    private var wantsScan = false

    private func log(_ m: String) { print("[G2] \(m)") }
    private func setStatus(_ s: G2Status, _ d: String = "") { status = s; detail = d }

    private func armFor(_ p: CBPeripheral) -> Arm? {
        if left.peripheral?.identifier == p.identifier { return left }
        if right.peripheral?.identifier == p.identifier { return right }
        return nil
    }

    // ---- connect / scan -----------------------------------------------------
    func connect() {
        guard status == .disconnected || status == .error else { return }
        userDisconnected = false
        setStatus(.scanning)
        wantsScan = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)   // nil → main queue
        } else if central?.state == .poweredOn {
            beginScan()
        }
    }

    private func beginScan() {
        wantsScan = false
        for a in arms { a.peripheral = nil; a.write = nil; a.notify = nil; a.ready = false }

        // An arm that iOS already holds a connection to (shows as "Connected" in
        // Settings → Bluetooth) is NEVER reported by scanForPeripherals. Adopt
        // those first, then scan only for whatever's left.
        adoptConnected()
        if left.peripheral != nil && right.peripheral != nil {
            log("both arms already connected - adopted, no scan needed")
            return
        }

        log("scanning for remaining arm(s)… (have L:\(left.peripheral != nil) R:\(right.peripheral != nil))")
        central?.scanForPeripherals(withServices: nil,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let t = DispatchWorkItem { [weak self] in
            guard let self, !(self.left.ready && self.right.ready) else { return }
            self.central?.stopScan()
            self.setStatus(.error, "Scan timeout - L:\(self.left.peripheral != nil) R:\(self.right.peripheral != nil)")
            self.log("scan timeout - L found:\(self.left.peripheral != nil) R found:\(self.right.peripheral != nil)")
        }
        scanTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: t)
    }

    /// Pick a slot for a peripheral by its name; nil if both slots are taken.
    private func slot(forName name: String) -> Arm? {
        let upper = name.uppercased()
        if upper.contains("_L_") || upper.contains("LEFT")  { return left.peripheral == nil ? left : nil }
        if upper.contains("_R_") || upper.contains("RIGHT") { return right.peripheral == nil ? right : nil }
        if left.peripheral == nil { return left }
        if right.peripheral == nil { return right }
        return nil
    }

    /// Adopt arms iOS is already connected to (scan won't surface those).
    private func adoptConnected() {
        guard let central else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [G2Protocol.serviceUUID])
        for p in connected {
            let name = p.name ?? ""
            guard name.contains("Even"), let arm = slot(forName: name) else { continue }
            log("adopting already-connected \(arm.side): '\(name)'")
            arm.peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
            setStatus(.connecting, "L:\(left.peripheral != nil) R:\(right.peripheral != nil)")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    if wantsScan { beginScan() }
        case .poweredOff:   setStatus(.error, "Bluetooth is off")
        case .unauthorized: setStatus(.error, "Bluetooth permission denied")
        case .unsupported:  setStatus(.error, "Bluetooth not supported")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        guard name.contains("Even") else { return }

        // Classify L/R by name; fall back to filling whichever slot is empty.
        let upper = name.uppercased()
        let arm: Arm
        if upper.contains("_L_") || upper.contains("LEFT")      { arm = left }
        else if upper.contains("_R_") || upper.contains("RIGHT") { arm = right }
        else if left.peripheral == nil                           { arm = left }
        else                                                     { arm = right }

        guard arm.peripheral == nil else { return }   // already have this side
        log("discovered \(arm.side): '\(name)' rssi=\(RSSI)")
        arm.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        setStatus(.connecting, "L:\(left.peripheral != nil) R:\(right.peripheral != nil)")

        if left.peripheral != nil && right.peripheral != nil {
            central.stopScan()
            scanTimeout?.cancel()
            log("both arms found - stopping scan")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let arm = armFor(peripheral)
        log("\(arm?.side ?? "?") didConnect - discovering ALL services")
        peripheral.discoverServices(nil)   // enumerate everything to map the real GATT
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("\(armFor(peripheral)?.side ?? "?") didFailToConnect: \(error?.localizedDescription ?? "unknown")")
        setStatus(.error, error?.localizedDescription ?? "Connection failed")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let arm = armFor(peripheral)
        log("\(arm?.side ?? "?") disconnected: \(error?.localizedDescription ?? "")")
        arm?.ready = false
        arm?.write = nil; arm?.notify = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        evenHubPrimed = false; imageMode = false; nativeMode = false; warmedUp = false  // re-prime on reconnect
        nativeCreated = false; lastListRows.removeAll(); lastTextContent.removeAll(); nativeShape = .none
        ehSession = 1; ehSeq = 0; ehMagic = 1; ehNeedsJump = false; ehAckMisses = 0
        tileFP.removeAll(); lastRenderFP = 0
        for (_, box) in pendingAcks { box.resolve(nil) }; pendingAcks.removeAll()
        let waiters = txReadyConts; txReadyConts.removeAll(); for c in waiters { c.resume() }

        if userDisconnected {
            setStatus(.disconnected, error?.localizedDescription ?? "")
            return
        }
        // Auto-reconnect the dropped arm (CoreBluetooth reconnects when it reappears).
        setStatus(.connecting, "reconnecting \(arm?.side ?? "?")…")
        if let p = arm?.peripheral {
            log("auto-reconnecting \(arm?.side ?? "?")…")
            central.connect(p, options: nil)
        } else {
            connect()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("didDiscoverServices error: \(error.localizedDescription)"); setStatus(.error, error.localizedDescription); return }
        guard let arm = armFor(peripheral) else { return }
        let services = peripheral.services ?? []
        arm.servicesTotal = services.count
        arm.servicesDone = 0
        log("\(arm.side) services (\(services.count)): \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for svc in services { peripheral.discoverCharacteristics(nil, for: svc) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let arm = armFor(peripheral) else { return }
        if let error { log("\(arm.side) char discovery error on \(service.uuid): \(error.localizedDescription)") }

        for ch in service.characteristics ?? [] {
            let props = propString(ch.properties)
            log("\(arm.side)   svc \(short(service.uuid)) char \(short(ch.uuid)) [\(props)]")

            // Subscribe to ANY characteristic that can notify/indicate, so we
            // capture the glasses' responses regardless of which channel they use.
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)   // subscribe to all, capture every reply
                let u = ch.uuid.uuidString.uppercased()
                if u.contains("2E5402") { arm.notify = ch }       // the control-channel notify
                else if arm.notify == nil { arm.notify = ch }
            }
            // Pick a write target: prefer the proprietary 2760 write char (…5401),
            // else the first writable characteristic we see.
            let canWrite = ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)
            if canWrite {
                let u = ch.uuid.uuidString.uppercased()
                if u.contains("2E5401") { arm.write = ch }            // control/teleprompter write
                else if u.contains("2E6401") { arm.displayWrite = ch } // binary image/render channel
                else if arm.write == nil { arm.write = ch }
            }
        }

        arm.servicesDone += 1
        guard arm.servicesDone >= arm.servicesTotal else { return }   // wait for full enumeration

        log("\(arm.side) GATT enumerated - write=\(arm.write.map { short($0.uuid) } ?? "NONE") notify=\(arm.notify.map { short($0.uuid) } ?? "NONE")")
        arm.ready = (arm.write != nil)

        if left.ready && right.ready {
            log("BOTH ARMS READY - authenticating")
            setStatus(.authenticating, "both arms")
            Task { @MainActor in await self.authenticate() }
        } else if arm.ready {
            setStatus(.connecting, "waiting for \(left.ready ? "R" : "L") arm")
        } else {
            setStatus(.error, "\(arm.side): no writable characteristic")
        }
    }

    private func short(_ u: CBUUID) -> String {
        let s = u.uuidString
        return s.count > 8 ? "…\(s.suffix(6))" : s
    }
    private func propString(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNR") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }

    // ---- notifications ------------------------------------------------------
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("notify error: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)

        log("◀ \(armFor(peripheral)?.side ?? "?") [\(short(characteristic.uuid))] recv (\(bytes.count)): \(hex(bytes))")
        // Decode EvenHub responses (RX sid 0xE0) so we can see accept/reject reasons.
        if bytes.count >= 9, bytes[0] == 0xAA, bytes[6] == EvenHub.sid {
            let pb = Array(bytes[8...])
            let flag = bytes[7]
            // Async events (flag 0x01/0x06: OS_NOTIFY / OS_PRIVATE) carry no matching
            // MagicRandom - dispatch them as taps, NOT as ack resolutions. Everything
            // else is a request ack → resolve the pending AckBox.
            if (flag == 0x01 || flag == 0x06), let ev = EvenHub.parseEvent(pb) {
                log("    ↳ EvenHub event \(ev)")
                DispatchQueue.main.async { self.dispatchEvent(ev) }
            } else {
                let r = EvenHub.parseResponse(pb)
                log("    ↳ \(EvenHub.describeResponse(pb))")
                if let box = pendingAcks.removeValue(forKey: r.magic) { box.resolve(r.result) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log("\(armFor(peripheral)?.side ?? "?") notify \(characteristic.isNotifying ? "ENABLED" : "disabled")\(error.map { " - \($0.localizedDescription)" } ?? "")")
    }

    /// Route a decoded native container event to the right callback.
    /// CLICK_EVENT==0 → activation; everything else → onPageEvent / lifecycle.
    // The firmware DOUBLE-DELIVERS one physical tap (2-3 identical CLICK events
    // back-to-back) - without a cooldown, one tap navigates several screens. And a
    // double-tap arrives as a SYS event (type 3), not a list/text click. So: scan
    // DOUBLE_CLICK from ANY channel first → back (gated), and gate single taps.
    private var lastTapAt = Date.distantPast
    private var lastBackAt = Date.distantPast
    private func tapGate() -> Bool {
        let n = Date(); if n.timeIntervalSince(lastTapAt) < 0.35 { return false }; lastTapAt = n; return true
    }
    private func backGate() -> Bool {
        let n = Date(); if n.timeIntervalSince(lastBackAt) < 0.45 { return false }; lastBackAt = n; return true
    }

    private func dispatchEvent(_ ev: EvenHub.InEvent) {
        // 1) DOUBLE_CLICK (eventType 3) from list / text / sys = back. Scanned first.
        let isDouble: Bool
        switch ev {
        case .listClick(_, _, _, 3), .textClick(_, 3), .sysEvent(3, _): isDouble = true
        default: isDouble = false
        }
        if isDouble { if backGate() { onDoubleTap?() }; return }

        switch ev {
        case .listClick(let name, let index, let itemName, let type):
            if type == 0 { if tapGate() { onListTap?(name, index, itemName) } }  // dedup duplicates
            else { onPageEvent?(name, type) }                                     // swipe/scroll
        case .textClick(let name, let type):
            if type == 0 { if tapGate() { onTextTap?(name) } } else { onPageEvent?(name, type) }
        case .sysEvent(let type, _):
            // FOREGROUND_EXIT(5)/ABNORMAL_EXIT(6)/SYSTEM_EXIT(7): page torn down.
            if type == 5 || type == 6 || type == 7 {
                evenHubPrimed = false; nativeCreated = false
                lastListRows.removeAll(); lastTextContent.removeAll(); nativeShape = .none
                heartbeatTask?.cancel(); heartbeatTask = nil
            }
            onPageEvent?("", type)
        case .privateEvent(let name, _, let eventData):
            onPageEvent?(name, eventData)
        case .other:
            break
        }
    }

    // ---- authentication (protobuf over the proprietary channel) -------------
    @MainActor
    private func authenticate() async {
        let ts = Int(Date().timeIntervalSince1970)
        for pkt in G2Protocol.authPackets(timestamp: ts) {
            await sendBoth(pkt)
            await sleep(100)
        }
        await sleep(500)
        setStatus(.ready, "ready")
        log("authenticated - READY")
        startHeartbeat()
    }

    // ---- text display (teleprompter, exact reference flow) ------------------
    /// Public entry: render `text` and keep it on the lens. The G2 teleprompter
    /// view times out on its own after ~18s, so we re-send periodically until the
    /// text changes or we disconnect. (BLE stays up the whole time via the
    /// heartbeat - this refresh is purely to keep the teleprompter VIEW alive.)
    @MainActor
    func displayText(_ text: String) async {
        imageMode = false                // switch out of image mode → text heartbeat
        lastText = text
        await sendTeleprompter(text)
        startDisplayRefresh()
    }

    func clearDisplay() {
        lastText = nil
        displayRefreshTask?.cancel(); displayRefreshTask = nil
    }

    private func startDisplayRefresh() {
        displayRefreshTask?.cancel()
        // The G2 teleprompter VIEW times out ~18s and only a content re-send
        // resets it, so re-send before then.
        displayRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 11_000_000_000)
                guard let self, let t = self.lastText, self.left.ready, self.right.ready else { continue }
                self.log("display refresh")
                await self.sendTeleprompter(t)
            }
        }
    }

    @MainActor
    private func sendTeleprompter(_ text: String) async {
        guard left.ready && right.ready else { log("displayText: arms not ready"); return }
        guard !imageMode else { log("sendTeleprompter skipped - image mode"); return }

        heartbeatTask?.cancel(); heartbeatTask = nil   // don't interleave with the flow
        let pages = G2Protocol.formatText(text)
        let totalLines = G2Protocol.inputLineCount(text)
        log("displayText: \(pages.count) pages, \(totalLines) input lines")

        var seq: UInt8 = 0x08
        var msgId = 0x14

        await sendBoth(G2Protocol.displayConfig(seq: seq, msgId: msgId)); seq &+= 1; msgId += 1
        await sleep(150)
        await sendBoth(G2Protocol.teleprompterInit(seq: seq, msgId: msgId, totalLines: totalLines)); seq &+= 1; msgId += 1
        await sleep(300)

        // Pages 0-9
        for i in 0..<min(10, pages.count) {
            await sendBoth(G2Protocol.contentPage(seq: seq, msgId: msgId, pageNum: i, text: pages[i])); seq &+= 1; msgId += 1
            await sleep(45)
        }
        // Mid-stream marker
        await sendBoth(G2Protocol.marker(seq: seq, msgId: msgId)); seq &+= 1; msgId += 1
        await sleep(45)
        // Pages 10-11
        if pages.count > 10 {
            for i in 10..<min(12, pages.count) {
                await sendBoth(G2Protocol.contentPage(seq: seq, msgId: msgId, pageNum: i, text: pages[i])); seq &+= 1; msgId += 1
                await sleep(100)
            }
        }
        // Sync trigger - activates rendering
        await sendBoth(G2Protocol.sync(seq: seq, msgId: msgId)); seq &+= 1; msgId += 1
        await sleep(45)
        // Remaining pages 12+
        if pages.count > 12 {
            for i in 12..<pages.count {
                await sendBoth(G2Protocol.contentPage(seq: seq, msgId: msgId, pageNum: i, text: pages[i])); seq &+= 1; msgId += 1
                await sleep(100)
            }
        }
        log("displayText: done")
        startHeartbeat()
    }

    // ---- image display (EvenHub container protocol) -------------------------
    //
    // A sliding window of in-flight Cmd=3 acks (throughput), BLE flow control via
    // canSendWriteWithoutResponse (no TX overflow → no reassembly abort), per-tile
    // fingerprint dedup, ack-miss tolerance, and a stuck-session jump
    // (MapSessionId += 2) + re-prime on a wedged stream. EvenHub traffic is
    // RIGHT ARM ONLY.
    private var evenHubPrimed = false
    private var imageMode = false
    private var nativeMode = false            // a native list/text container is the live page
    private var warmedUp = false

    // Native HUD dedup caches (skip a re-send when content is unchanged).
    private var lastListRows: [String: [String]] = [:]
    private var lastTextContent: [String: String] = [:]
    private enum NativeShape { case none, list, text }
    private var nativeShape: NativeShape = .none   // current shape of the single HUD container
    // Names already CREATEd in this EvenHub session (Cmd=0 once, Cmd=7 thereafter).
    private var nativeListName = "hud"      // single full-lens container, list↔text in place
    private var nativeCreated = false
    private var ehSeq: UInt8 = 0
    private var ehMagic = 1
    private var ehSession = 1
    private var ehNeedsJump = false           // bump MapSessionId by 2 to escape a poisoned session
    private var ehAckMisses = 0               // lifetime counter (diagnostic)
    private let ehWindow = 4                   // in-flight Cmd=3 acks
    private var tileFP: [Int: Int] = [:]       // containerId → last-streamed bmp fingerprint
    private var lastRenderFP = 0               // whole-frame dedup

    /// BLE write chunk sized to the negotiated MTU (frames bigger than the MTU
    /// are silently dropped → reassembly abort). 8 = envelope header.
    private var ehChunk: Int {
        let maxW = right.peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 180
        return max(20, min(232, maxW - 8))
    }

    private func nextEhSeq() -> UInt8 { defer { ehSeq = ehSeq &+ 1 }; return ehSeq }
    private func nextMagic() -> Int { defer { ehMagic = ehMagic >= 120 ? 1 : ehMagic + 1 }; return ehMagic }
    /// Next MapSessionId. Steps by 2 after a wedge so the new session does not
    /// inherit the aborted session's poisoned buffers (stuck-session trap).
    private func nextSession() -> Int {
        let step = ehNeedsJump ? 2 : 1; ehNeedsJump = false
        ehSession += step
        if ehSession >= 250 { ehSession = 2 }
        return ehSession
    }
    private func fp(_ b: [UInt8]) -> Int { var h = Hasher(); h.combine(b); return h.finalize() }
    /// EvenHub result codes: success is EVEN (createOK=0, imageOK=4, rebuildOK=6,
    /// textOK=8, shutdownOK=10, heartbeatOK=12); failure is ODD (1/5/7/9/11).
    private func ehOK(_ r: Int?) -> Bool { (r ?? 1) % 2 == 0 }

    /// One pending EvenHub ack. Resolves once, from either the notify handler or
    /// the timeout, whichever is first. All access is on the main (CB) queue, so
    /// no isolation is needed - matching the surrounding delegate callbacks.
    final class AckBox {
        private var value: Int?
        private var resolved = false
        private var cont: CheckedContinuation<Int?, Never>?
        var timeout: Task<Void, Never>?            // torn down the instant the real ack lands
        func resolve(_ r: Int?) {
            guard !resolved else { return }
            resolved = true; value = r
            timeout?.cancel(); timeout = nil
            if let c = cont { cont = nil; c.resume(returning: r) }
        }
        func wait() async -> Int? {
            if resolved { return value }
            return await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
                if resolved { c.resume(returning: value) } else { cont = c }
            }
        }
    }
    private var pendingAcks: [Int: AckBox] = [:]

    // ---- BLE flow control (right arm) ---------------------------------------
    // write-without-response is silently DROPPED when the iOS TX queue is full,
    // with no error - the cause of the E0 02 reassembly abort under a burst.
    // Honor canSendWriteWithoutResponse / peripheralIsReady so we drain at the
    // radio's pace instead of overflowing it.
    private var txReadyConts: [CheckedContinuation<Void, Never>] = []

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === right.peripheral else { return }
        let conts = txReadyConts; txReadyConts.removeAll()
        for c in conts { c.resume() }
    }

    @MainActor
    private func writeRightFlow(_ data: [UInt8]) async {
        guard let p = right.peripheral, let w = right.write else { return }
        // Bail (don't re-park) if the arm drops mid-burst - peripheralIsReady will
        // never fire for a disconnected peripheral, so re-suspending would hang the
        // whole stream chain. disconnect() resumes any parked waiter; this guard
        // makes the resumed task fall through instead of re-appending.
        while p.state == .connected && !p.canSendWriteWithoutResponse {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if p.canSendWriteWithoutResponse || p.state != .connected { c.resume() }
                else { txReadyConts.append(c) }
            }
        }
        guard p.state == .connected else { return }
        p.writeValue(Data(data), for: w, type: .withoutResponse)
    }

    /// Fire one EvenHub message (right arm, flow-controlled) and return its ack
    /// box WITHOUT awaiting - the caller decides when to drain (sliding window).
    /// The timeout is armed only AFTER the frames are written, so backpressure
    /// can't time the ack out before the firmware has even seen the message.
    @MainActor
    private func fireEvenHub(_ pb: [UInt8], magic: Int, timeoutMs: Int) async -> AckBox {
        let box = AckBox()
        pendingAcks[magic] = box
        let frames = G2Protocol.framePb(seq: nextEhSeq(), sid: EvenHub.sid, flag: EvenHub.flagRequest, pb, chunk: ehChunk)
        for f in frames { await writeRightFlow(f) }
        box.timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            if pendingAcks[magic] === box { pendingAcks.removeValue(forKey: magic); box.resolve(nil) }
        }
        return box
    }

    /// One-shot fire-and-wait (prelude / create).
    @MainActor
    private func sendEvenHubAck(_ pb: [UInt8], magic: Int, timeoutMs: Int = 3000) async -> Int? {
        await fireEvenHub(pb, magic: magic, timeoutMs: timeoutMs).wait()
    }

    /// 2×2 image-container grid covering the full 576×288 lens. Declared once.
    private let grid: [EvenHub.ImageContainer] = [
        .init(id: 10, name: "t0", x: 0,   y: 0,   w: 288, h: 144),
        .init(id: 11, name: "t1", x: 288, y: 0,   w: 288, h: 144),
        .init(id: 12, name: "t2", x: 0,   y: 144, w: 288, h: 144),
        .init(id: 13, name: "t3", x: 288, y: 144, w: 288, h: 144),
    ]

    /// Prelude + create the 4-tile image page (mandatory; primes the plugin task).
    /// Does NOT start the heartbeat - callers manage that around the stream burst.
    @MainActor
    private func primeEvenHub() async {
        if nativeCreated {                              // native page is up → tear it down first
            let m = nextMagic()
            _ = await fireEvenHub(EvenHub.shutDown(magic: m), magic: m, timeoutMs: 1500).wait()
            nativeCreated = false; nativeMode = false; evenHubPrimed = false
            lastListRows.removeAll(); lastTextContent.removeAll(); nativeShape = .none
            await sleep(150)
        }
        guard !evenHubPrimed else { return }
        log("EvenHub prime: prelude + create 2×2 grid (MTU chunk \(ehChunk))")
        writeTo(right, EvenHub.prelude)                  // sid 0x01 app-launch, right arm only
        await sleep(500)
        let cr = await sendEvenHubAck(EvenHub.createStartupPageImages(grid), magic: 201)
        log("create ack: \(cr.map { $0 == 0 ? "createOK" : "result=\($0)" } ?? "no-ack")")
        evenHubPrimed = true
        imageMode = true
        await sleep(200)
    }

    // ---- native list/text container (fast, tappable; no image streaming) ----
    //
    // CREATE the page ONCE per session, then flip list↔text in place via Cmd=7
    // rebuild (and stream cheap Cmd=5 text upgrades). EvenHub traffic is RIGHT
    // ARM ONLY. Heartbeat (Cmd=12) gates on evenHubPrimed.

    /// Prelude + Cmd=0 CREATE the native page (idempotent). Switches the
    /// connection into native mode and out of image mode.
    @MainActor
    private func primeNative() async {
        guard !nativeCreated else { return }
        // CREATE the page exactly ONCE per session. Do NOT shut down / recreate on
        // navigation - a shutdown makes the firmware fire SYSTEM_EXIT and the
        // recreated page loses tap-event focus (taps die after one screen).
        log("EvenHub prime (native): prelude + create single full-lens container '\(nativeListName)'")
        if !evenHubPrimed {
            writeTo(right, EvenHub.prelude)                 // sid 0x01 app-launch, right arm only
            await sleep(500)
        }
        // ONE full-lens container, rebuilt in place to flip list↔text. No second
        // (overlapping) container - that caused ID collision + bleed-through.
        let pb = EvenHub.createList(name: nativeListName, items: ["…"], magic: 201)
        let cr = await sendEvenHubAck(pb, magic: 201)
        log("native create ack: \(cr.map { $0 == 0 ? "createOK" : "result=\($0)" } ?? "no-ack")")
        evenHubPrimed = true
        nativeMode = true
        imageMode = false
        nativeCreated = true             // create-once; only re-prime after a real SYSTEM_EXIT
        await sleep(200)
    }

    /// CREATE-or-REBUILD the visible list (Cmd=7 after prime).
    @MainActor
    func displayList(name: String, rows: [String]) async {
        await updateList(name: name, rows: rows)
    }

    /// Cmd=7 rebuild a list container (same name). Deduped.
    @MainActor
    func updateList(name: String, rows: [String]) async {
        await enqueueStream { [weak self] in await self?.updateListImpl(name: name, rows: rows) }
    }

    @MainActor
    private func updateListImpl(name: String, rows: [String]) async {
        guard right.ready else { log("updateList: right arm not ready"); return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        await primeNative()
        // Dedup ONLY when this container is already foreground - otherwise a screen
        // switch (e.g. Back from text) with unchanged rows would be skipped and
        // strand the user on the previous container.
        if nativeShape == .list && lastListRows[name] == rows {
            log("updateList \(name): deduped"); startHeartbeat(); return
        }
        let magic = nextMagic()
        let pb = EvenHub.rebuildList(name: name, items: rows, magic: magic)
        let r = await fireEvenHub(pb, magic: magic, timeoutMs: 3000).wait()
        if ehOK(r) { lastListRows[name] = rows; lastTextContent[name] = nil; nativeShape = .list }
        log("updateList \(name) (\(rows.count) rows): result=\(r.map(String.init) ?? "no-ack")\(ehOK(r) ? " OK" : "")")
        startHeartbeat()
    }

    /// Cmd=7 switch the container to a TEXT shape with content.
    @MainActor
    func showText(name: String, content: String) async {
        await enqueueStream { [weak self] in await self?.showTextImpl(name: name, content: content) }
    }

    @MainActor
    private func showTextImpl(name: String, content: String) async {
        guard right.ready else { log("showText: right arm not ready"); return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        await primeNative()
        let magic = nextMagic()
        let pb = EvenHub.rebuildText(name: name, content: content, captureEvents: true, magic: magic)
        let r = await fireEvenHub(pb, magic: magic, timeoutMs: 3000).wait()
        if ehOK(r) { lastTextContent[name] = content; lastListRows[name] = nil; nativeShape = .text }
        log("showText \(name) (\(content.utf8.count)B): result=\(r.map(String.init) ?? "no-ack")\(ehOK(r) ? " OK" : "")")
        startHeartbeat()
    }

    /// Cmd=5 in-place text upgrade (cheap, flicker-free). Deduped.
    @MainActor
    func updateText(name: String, content: String) async {
        await enqueueStream { [weak self] in await self?.updateTextImpl(name: name, content: content) }
    }

    @MainActor
    private func updateTextImpl(name: String, content: String) async {
        guard right.ready else { return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        await primeNative()
        // Cmd=5 only works once the text shape is foreground. If it isn't, promote
        // via a Cmd=7 showText (shape switch) instead of a no-op upgrade.
        if nativeShape != .text {
            await showTextImpl(name: name, content: content)   // promote list→text shape first
            return
        }
        if lastTextContent[name] == content {
            log("updateText \(name): deduped"); startHeartbeat(); return
        }
        let magic = nextMagic()
        let pb = EvenHub.textUpgrade(name: name, content: content, magic: magic)
        let r = await fireEvenHub(pb, magic: magic, timeoutMs: 3000).wait()
        if ehOK(r) { lastTextContent[name] = content }
        log("updateText \(name) (\(content.utf8.count)B): result=\(r.map(String.init) ?? "no-ack")\(ehOK(r) ? " OK" : "")")
        startHeartbeat()
    }

    /// Cmd=9 shutdown the native page (optional cleanup).
    @MainActor
    func shutdownNative() async {
        await enqueueStream { [weak self] in
            guard let self, self.right.ready else { return }
            let magic = self.nextMagic()
            _ = await self.fireEvenHub(EvenHub.shutDown(magic: magic), magic: magic, timeoutMs: 1500).wait()
            self.nativeCreated = false; self.nativeMode = false
            self.lastListRows.removeAll(); self.lastTextContent.removeAll()
        }
    }

    // Serialize every stream burst: two concurrent renders would interleave
    // fragments and collide on shared ehSeq/ehMagic/pendingAcks, corrupting the
    // lens. All render entry points queue through here, so they must not overlap.
    private var streamTask: Task<Void, Never>?
    @MainActor
    private func enqueueStream(_ op: @escaping () async -> Void) async {
        let prev = streamTask
        let t = Task { @MainActor in _ = await prev?.value; await op() }
        streamTask = t
        await t.value
    }

    /// Render a full-lens 576×288 CoreGraphics drawing as a 2×2 tile grid.
    @MainActor
    func displayComponent(_ draw: @escaping (CGContext) -> Void) async {
        await enqueueStream { [weak self] in await self?.renderFrame(draw) }
    }

    @MainActor
    private func renderFrame(_ draw: (CGContext) -> Void) async {
        guard left.ready && right.ready else { log("displayComponent: not ready"); return }
        heartbeatTask?.cancel(); heartbeatTask = nil     // stop heartbeat BEFORE priming / streaming
        imageMode = true; nativeMode = false             // image grid != native HUD (separate lifecycle)
        clearDisplay()
        await primeEvenHub()
        let rendered = EvenHub.renderTiles(fullW: 576, fullH: 288, tileW: 288, tileH: 144, draw: draw)
        let tiles: [(c: EvenHub.ImageContainer, bmp: [UInt8])] =
            rendered.enumerated().compactMap { i, t in i < grid.count ? (grid[i], t.bmp) : nil }

        var fh = Hasher(); for (_, b) in tiles { fh.combine(b) }
        let frameFP = fh.finalize()
        if frameFP == lastRenderFP && warmedUp {
            log("displayComponent: deduped (unchanged frame)"); startHeartbeat(); return
        }

        if !warmedUp, let first = tiles.first, await streamWarmup(grid[0], bmp: first.bmp) { warmedUp = true }
        var ok = await streamTiles(tiles)
        if !ok {                                          // wedged → jump session, re-prime, retry once
            await recoverImageSession()
            if !warmedUp, let first = tiles.first, await streamWarmup(grid[0], bmp: first.bmp) { warmedUp = true }
            ok = await streamTiles(tiles)
        }
        lastRenderFP = ok ? frameFP : 0
        startHeartbeat()
        log("displayComponent: \(ok ? "ok" : "FAILED") (\(tiles.count) tiles, \(ehAckMisses) lifetime ack-misses)")
    }

    /// Display a single 288×144 image in the top-left tile (e.g. the test pattern).
    @MainActor
    func displayImage(_ bmp: [UInt8], width: Int = 288, height: Int = 144) async {
        await enqueueStream { [weak self] in await self?.renderImage(bmp) }
    }

    @MainActor
    private func renderImage(_ bmp: [UInt8]) async {
        guard left.ready && right.ready, !bmp.isEmpty else { log("displayImage: not ready/empty"); return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        imageMode = true; nativeMode = false             // image grid != native HUD (separate lifecycle)
        clearDisplay()
        await primeEvenHub()
        if !warmedUp, await streamWarmup(grid[0], bmp: bmp) { warmedUp = true }
        var ok = await streamTiles([(grid[0], bmp)])
        if !ok { await recoverImageSession(); ok = await streamTiles([(grid[0], bmp)]) }
        startHeartbeat()
        log("displayImage: \(ok ? "ok" : "FAILED")")
    }

    /// Sacrificial first stream - the firmware silently drops the first Cmd=3
    /// burst after a CREATE. Sequential + patient; not fingerprinted, so the real
    /// frame still streams afterwards.
    @MainActor
    private func streamWarmup(_ c: EvenHub.ImageContainer, bmp: [UInt8]) async -> Bool {
        let sid = nextSession()
        var idx = 0, off = 0
        while off < bmp.count {
            let end = min(off + 3800, bmp.count)
            let magic = nextMagic()
            let pb = EvenHub.imageRawData(containerId: c.id, name: c.name, sessionId: sid,
                                          totalSize: bmp.count, fragmentIndex: idx, data: Array(bmp[off..<end]), magic: magic)
            if await fireEvenHub(pb, magic: magic, timeoutMs: 10000).wait() == nil {
                log("warmup \(c.name) frag \(idx): no ack - abort"); return false
            }
            idx += 1; off = end
        }
        log("warmup \(c.name): ok"); return true
    }

    /// Stream tiles with a sliding window + per-tile dedup + ack-miss tolerance.
    /// Returns false if the stream wedged (>3 consecutive ack misses).
    @MainActor
    private func streamTiles(_ tiles: [(c: EvenHub.ImageContainer, bmp: [UInt8])]) async -> Bool {
        var inFlight: [AckBox] = []
        var consecMiss = 0
        var aborted = false

        func drainOne() async {
            guard !inFlight.isEmpty else { return }
            let r = await inFlight.removeFirst().wait()
            if r == 4 { consecMiss = 0 }
            else { consecMiss += 1; ehAckMisses += 1; if consecMiss > 3 { aborted = true } }
        }

        var streamed: [(Int, Int)] = []                  // (containerId, fp) pending dedup-commit
        outer: for (c, bmp) in tiles {
            let f = fp(bmp)
            if tileFP[c.id] == f { log("tile \(c.name): deduped"); continue }
            await sendImageHeartbeatInline()              // keep plugin task alive between tiles
            let sid = nextSession()
            var idx = 0, off = 0
            while off < bmp.count {
                if aborted { break outer }
                while inFlight.count >= ehWindow { await drainOne(); if aborted { break outer } }
                let end = min(off + 3800, bmp.count)
                let magic = nextMagic()
                let pb = EvenHub.imageRawData(containerId: c.id, name: c.name, sessionId: sid,
                                              totalSize: bmp.count, fragmentIndex: idx, data: Array(bmp[off..<end]), magic: magic)
                inFlight.append(await fireEvenHub(pb, magic: magic, timeoutMs: 1000))
                idx += 1; off = end
            }
            if !aborted { streamed.append((c.id, f)) }
        }
        // Drain the tail through the SAME accounting so a final-window miss aborts
        // (otherwise a tile whose trailing fragments were swallowed would be cached
        // and never re-sent). Then flush any remainder if we already gave up.
        while !inFlight.isEmpty && !aborted { await drainOne() }
        while !inFlight.isEmpty { _ = await inFlight.removeFirst().wait() }

        if aborted { log("streamTiles: wedged (>3 consecutive ack misses)"); return false }
        for (id, f) in streamed { tileFP[id] = f }       // commit dedup only on a fully-acked stream
        return true
    }

    /// One EvenHub Cmd=12 heartbeat written between messages (a safe point - no
    /// fragment is mid-flight on the wire) so the plugin watchdog (~10s) never
    /// fires during a long full-lens burst. Fire-and-forget (right arm).
    @MainActor
    private func sendImageHeartbeatInline() async {
        let frames = G2Protocol.framePb(seq: nextEhSeq(), sid: EvenHub.sid,
                                        flag: EvenHub.flagRequest, EvenHub.heartbeat(magic: nextMagic()))
        for f in frames { await writeRightFlow(f) }
    }

    /// Escape a wedged plugin task: jump MapSessionId by 2, drop caches, re-prime.
    @MainActor
    private func recoverImageSession() async {
        log("recovering image session (session jump +2 + re-prime)")
        ehNeedsJump = true
        warmedUp = false
        tileFP.removeAll()
        lastRenderFP = 0
        ehAckMisses = 0
        evenHubPrimed = false
        heartbeatTask?.cancel(); heartbeatTask = nil
        await primeEvenHub()
        heartbeatTask?.cancel(); heartbeatTask = nil
    }

    /// Mirror a packet to both arms (left, brief pause, right).
    private func sendBoth(_ data: [UInt8]) async {
        writeTo(left, data)
        await sleep(18)
        writeTo(right, data)
        await sleep(12)
    }

    private func writeTo(_ arm: Arm, _ data: [UInt8]) {
        guard let p = arm.peripheral, let w = arm.write else { log("\(arm.side): write skipped - not ready"); return }
        log("▶ \(arm.side) (\(data.count)): \(hex(Array(data.prefix(12))))\(data.count > 12 ? " …" : "")")
        p.writeValue(Data(data), for: w, type: .withoutResponse)
    }

    // ---- heartbeat ----------------------------------------------------------
    private var hbSeq: UInt8 = 0xC0
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        // A structured-concurrency loop, not a Timer - fires reliably regardless
        // of run-loop mode / idle state.
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sendHeartbeat()
                // Faster than the glasses' 2000ms supervision timeout so the link
                // never goes idle.
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // every 1.5s
            }
        }
    }

    private func sendHeartbeat() {
        // Native mode only needs the right arm; image/teleprompter need both.
        if nativeMode {
            guard right.ready, evenHubPrimed else { return }
            let frames = G2Protocol.framePb(seq: nextEhSeq(), sid: EvenHub.sid,
                                            flag: EvenHub.flagRequest, EvenHub.heartbeat(magic: nextMagic()))
            for f in frames { writeTo(right, f) }
            return
        }
        guard left.ready, right.ready else { return }
        if imageMode {
            // EvenHub plugin-task heartbeat (Cmd=12, sid 0xE0) keeps image renders
            // alive. RIGHT ARM ONLY (sid 0xE0 on the left wedges the plugin task),
            // and never before the first CREATE exists (the plugin task doesn't
            // exist yet).
            guard evenHubPrimed else { return }
            let frames = G2Protocol.framePb(seq: nextEhSeq(), sid: EvenHub.sid,
                                            flag: EvenHub.flagRequest, EvenHub.heartbeat(magic: nextMagic()))
            for f in frames { writeTo(right, f) }
        } else {
            let hb = G2Protocol.heartbeat(seq: hbSeq)
            hbSeq = hbSeq &+ 1
            if hbSeq == 0 { hbSeq = 0xC0 }
            writeTo(left, hb); writeTo(right, hb)
        }
    }

    // ---- utilities ----------------------------------------------------------
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func disconnect() {
        userDisconnected = true
        displayRefreshTask?.cancel(); displayRefreshTask = nil
        lastText = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        scanTimeout?.cancel(); scanTimeout = nil
        for a in arms {
            if let p = a.peripheral { central?.cancelPeripheralConnection(p) }
            a.peripheral = nil; a.write = nil; a.notify = nil; a.ready = false
        }
        setStatus(.disconnected)
    }

    deinit {
        heartbeatTask?.cancel()
        for a in arms { if let p = a.peripheral { central?.cancelPeripheralConnection(p) } }
    }
}

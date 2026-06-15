// Even Realities G2 BLE protocol - teleprompter text display + framing.
//
// Ported verbatim from a verified-working reference implementation (which is a
// byte-for-byte port of the community even-g2-protocol reference). See
// PROTOCOL.md §4, §5, §8. The verified byte sequences MUST stay exact - the
// firmware silently drops anything malformed.
//
// Frame: [0xAA] [0x21] [seq] [len=payload+2] [01] [01] [svc_hi] [svc_lo] [payload] [crc_lo] [crc_hi]
//   • CRC = CRC16/CCITT-FALSE over the payload only, little-endian.
//   • Display flow: auth(7) → displayConfig → init → pages 0-9 → marker → pages 10-11 → sync → pages 12+.

import Foundation
import CoreBluetooth

enum G2Protocol {

    // ---- GATT UUIDs ---------------------------------------------------------
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")  // retrieveConnected filter
    static let writeUUID   = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5401")  // writeNR
    static let notifyUUID  = CBUUID(string: "00002760-08c2-11e1-9073-0e8ac72e5402")  // notify

    // ---- framing ------------------------------------------------------------
    static func encodeVarint(_ value: Int) -> [UInt8] {
        var v = value, out = [UInt8]()
        while v > 0x7F { out.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        out.append(UInt8(v & 0x7F))
        return out
    }

    /// Multi-fragment envelope (for payloads > one BLE chunk, e.g. EvenHub
    /// image data). CRC16 over the whole payload, appended LE to the LAST
    /// fragment; all fragments share `seq` (the firmware's reassembly key).
    static func framePb(seq: UInt8, sid: UInt8, flag: UInt8, _ pb: [UInt8], chunk: Int = 232) -> [[UInt8]] {
        let crcv = CRC16.ccitt(pb)
        let crc: [UInt8] = [UInt8(crcv & 0xFF), UInt8((crcv >> 8) & 0xFF)]
        let totalFrags = max(1, (pb.count + 2 + chunk - 1) / chunk)
        var frames: [[UInt8]] = []
        var off = 0
        for i in 0..<totalFrags {
            let isLast = i == totalFrags - 1
            let chunkBytes: [UInt8]
            if isLast {
                chunkBytes = Array(pb[off...]) + crc
                off = pb.count
            } else {
                chunkBytes = Array(pb[off..<min(off + chunk, pb.count)])
                off += chunk
            }
            var frame: [UInt8] = [0xAA, 0x21, seq, UInt8(chunkBytes.count & 0xFF),
                                  UInt8(totalFrags), UInt8(i + 1), sid, flag]
            frame += chunkBytes
            frames.append(frame)
        }
        return frames
    }

    static func buildPacket(seq: UInt8, _ svcHi: UInt8, _ svcLo: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var pkt: [UInt8] = [0xAA, 0x21, seq, UInt8((payload.count + 2) & 0xFF), 0x01, 0x01, svcHi, svcLo]
        pkt += payload
        let crc = CRC16.ccitt(payload)
        pkt.append(UInt8(crc & 0xFF))
        pkt.append(UInt8((crc >> 8) & 0xFF))
        return pkt
    }

    private static func hexBytes(_ s: String) -> [UInt8] {
        let clean = s.filter { $0.isHexDigit }
        var out = [UInt8](); out.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            out.append(UInt8(clean[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    // ---- authentication (7 packets) -----------------------------------------
    static func authPackets(timestamp: Int) -> [[UInt8]] {
        let ts = encodeVarint(timestamp)
        let txid: [UInt8] = [0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        var pkts: [[UInt8]] = []
        pkts.append(buildPacket(seq: 0x01, 0x80, 0x00, [0x08,0x04,0x10,0x0C,0x1A,0x04,0x08,0x01,0x10,0x04]))
        pkts.append(buildPacket(seq: 0x02, 0x80, 0x20, [0x08,0x05,0x10,0x0E,0x22,0x02,0x08,0x02]))
        pkts.append(buildPacket(seq: 0x03, 0x80, 0x20, [0x08,0x80,0x01,0x10,0x0F,0x82,0x08,0x11,0x08] + ts + [0x10] + txid))
        pkts.append(buildPacket(seq: 0x04, 0x80, 0x00, [0x08,0x04,0x10,0x10,0x1A,0x04,0x08,0x01,0x10,0x04]))
        pkts.append(buildPacket(seq: 0x05, 0x80, 0x00, [0x08,0x04,0x10,0x11,0x1A,0x04,0x08,0x01,0x10,0x04]))
        pkts.append(buildPacket(seq: 0x06, 0x80, 0x20, [0x08,0x05,0x10,0x12,0x22,0x02,0x08,0x01]))
        pkts.append(buildPacket(seq: 0x07, 0x80, 0x20, [0x08,0x80,0x01,0x10,0x13,0x82,0x08,0x11,0x08] + ts + [0x10] + txid))
        return pkts
    }

    // ---- teleprompter packets -----------------------------------------------
    static func displayConfig(seq: UInt8, msgId: Int) -> [UInt8] {
        let config = hexBytes(
            "08011213080210904E1D00E0944425000000002800300012130803100D0F1D0040" +
            "8D442500000000280030001212080410001D000088422500000000280030001212" +
            "080510001D00009242250000A242280030001212080610001D0000C642250000C4" +
            "4228003000" + "1800")
        let payload: [UInt8] = [0x08, 0x02, 0x10] + encodeVarint(msgId) + [0x22, 0x6A] + config
        return buildPacket(seq: seq, 0x0E, 0x20, payload)
    }

    static func teleprompterInit(seq: UInt8, msgId: Int, totalLines: Int, manual: Bool = true) -> [UInt8] {
        let mode: UInt8 = manual ? 0x00 : 0x01
        let contentHeight = max(1, (totalLines * 2665) / 140)
        var display: [UInt8] = [0x08,0x01,0x10,0x00,0x18,0x00,0x20,0x8B,0x02]   // fixed: script idx, sub2/3, width 267
        display += [0x28] + encodeVarint(contentHeight)                          // content height
        display += [0x30, 0xE6, 0x01]                                            // line height 230
        display += [0x38, 0x8E, 0x0A]                                            // viewport 1294
        display += [0x40, 0x05, 0x48, mode]                                      // font 5 + scroll mode
        let settings: [UInt8] = [0x08, 0x01, 0x12, UInt8(display.count)] + display
        let payload: [UInt8] = [0x08, 0x01, 0x10] + encodeVarint(msgId) + [0x1A, UInt8(settings.count)] + settings
        return buildPacket(seq: seq, 0x06, 0x20, payload)
    }

    static func contentPage(seq: UInt8, msgId: Int, pageNum: Int, text: String) -> [UInt8] {
        let textBytes = Array(("\n" + text).utf8)
        let inner: [UInt8] = [0x08] + encodeVarint(pageNum) + [0x10, 0x0A] + [0x1A] + encodeVarint(textBytes.count) + textBytes
        let content: [UInt8] = [0x2A] + encodeVarint(inner.count) + inner
        let payload: [UInt8] = [0x08, 0x03, 0x10] + encodeVarint(msgId) + content
        return buildPacket(seq: seq, 0x06, 0x20, payload)
    }

    static func marker(seq: UInt8, msgId: Int) -> [UInt8] {
        let payload: [UInt8] = [0x08, 0xFF, 0x01, 0x10] + encodeVarint(msgId) + [0x6A, 0x04, 0x08, 0x00, 0x10, 0x06]
        return buildPacket(seq: seq, 0x06, 0x20, payload)
    }

    static func sync(seq: UInt8, msgId: Int) -> [UInt8] {
        let payload: [UInt8] = [0x08, 0x0E, 0x10] + encodeVarint(msgId) + [0x6A, 0x00]
        return buildPacket(seq: seq, 0x80, 0x00, payload)
    }

    static func heartbeat(seq: UInt8) -> [UInt8] {
        buildPacket(seq: seq, 0x80, 0x00, [0x08, 0x25])
    }

    // ---- text formatting ----------------------------------------------------
    /// Wrap into ≤25-char lines, 10 lines/page, ≥14 pages. Returns page strings.
    static func formatText(_ input: String, charsPerLine: Int = 25, linesPerPage: Int = 10) -> [String] {
        let text = input.replacingOccurrences(of: "\\n", with: "\n")
        var wrapped: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { wrapped.append(""); continue }
            var current = ""
            for word in line.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                if current.count + word.count + 1 > charsPerLine {
                    let t = current.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { wrapped.append(t) }
                    current = word + " "
                } else {
                    current += word + " "
                }
            }
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { wrapped.append(t) }
        }
        if wrapped.isEmpty { wrapped = [text] }
        while wrapped.count < linesPerPage { wrapped.append(" ") }

        var pages: [String] = []
        var i = 0
        while i < wrapped.count {
            var pageLines = Array(wrapped[i..<min(i + linesPerPage, wrapped.count)])
            while pageLines.count < linesPerPage { pageLines.append(" ") }
            pages.append(pageLines.joined(separator: "\n") + " \n")
            i += linesPerPage
        }
        while pages.count < 14 {
            pages.append(Array(repeating: " ", count: linesPerPage).joined(separator: "\n") + " \n")
        }
        return pages
    }

    static func inputLineCount(_ input: String) -> Int {
        input.replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "\n").count
    }
}

// CRC-16/CCITT-FALSE for G2 packet framing.
// Polynomial 0x1021, init 0xFFFF, no final XOR, MSB-first.
//
// Ported verbatim from a verified-working reference implementation. See
// PROTOCOL.md §3. The bytes are correct; do not "improve" them.

import Foundation

enum CRC16 {
    /// Precomputed lookup table (built once, lazily).
    private static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt16(i) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
            t[i] = crc
        }
        return t
    }()

    static func ccitt(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc = (crc << 8) ^ table[Int(((crc >> 8) ^ UInt16(b)) & 0xFF)]
        }
        return crc
    }
}

// Test bitmaps for the G2 EvenHub image path. Produces 4-bpp gray4 BMPs via
// EvenHub.bmp4 (the format the firmware's image renderer expects).
//
// Ported from the reference implementation. Useful for a `displayImage(GlassImage.testPattern())`
// smoke test before wiring up the HTTP /image endpoint.

import CoreGraphics
import Foundation

enum GlassImage {
    static let tileWidth = 288    // single tile - firmware max per image (~20KB); full lens needs 2x2 tiling
    static let tileHeight = 144

    /// Geometric test pattern: border, centre filled box, asymmetric top-left
    /// marker (to detect orientation / mirroring) - pure shapes, no text.
    static func testPattern() -> [UInt8] {
        EvenHub.bmp4(width: tileWidth, height: tileHeight) { ctx in
            let w = CGFloat(tileWidth), h = CGFloat(tileHeight)
            ctx.setLineWidth(3)
            ctx.stroke(CGRect(x: 2, y: 2, width: w - 4, height: h - 4))            // border
            ctx.fill(CGRect(x: w/2 - 50, y: h/2 - 25, width: 100, height: 50))     // centre box
            ctx.fill(CGRect(x: 12, y: h - 40, width: 28, height: 28))              // top-left marker (CG y-up)
            ctx.move(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: w - 2, y: h - 2)); ctx.strokePath()  // diagonal
        }
    }
}

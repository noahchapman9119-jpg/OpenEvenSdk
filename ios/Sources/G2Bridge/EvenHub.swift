// EvenHub native containers + image protocol for Even G2.
//
// Ported from a verified-working reference implementation. See PROTOCOL.md §9.
// The mic / LC3 audio path (Cmd=15 audioCtrl / Cmd=16 audioRes) is intentionally
// REMOVED for the g2-bridge v1 (optional per the spec). Everything else - field
// numbers, the 4-bpp BMP builder, 2×2 tile rendering, native list/text/page
// builders, the event/response parsers - is kept verbatim.
//
// Wire model: arbitrary UI is a 4-bpp BMP streamed into an "image container"
// over the SAME write char as text (…2E5401), in the SAME AA envelope, with
// sid = 0xE0 (EvenHub) and an inner protobuf wrapper whose field 1 = Cmd.
// Sequence: app-launch prelude → create startup page → EvenHub heartbeat (1.5s)
// → rebuild declaring image container(s) → stream Cmd=3 pixel fragments.

import CoreGraphics
import CoreText
import Foundation

enum EvenHub {

    static let sid: UInt8 = 0xE0
    static let flagRequest: UInt8 = 0x20

    // Cmd values (evenhub_main_msg_ctx field 1 = EvenHub_Cmd_List). proto3 omits 0.
    // create=0, event(RX)=2, updateImage=3, updateText=5, rebuild=7, shutdown=9,
    // privateEvent(RX)=11, heartbeat=12. (audioCtrl=15 / audioRes=16 removed in v1.)
    enum Cmd {
        static let create = 0, event = 2, updateImage = 3, updateText = 5,
                   rebuild = 7, shutdown = 9, privateEvent = 11, heartbeat = 12
    }

    /// Container names must be <= 14 chars or the firmware silently rejects them.
    static func validName(_ name: String) -> String {
        precondition(name.utf8.count <= 14, "EvenHub container name '\(name)' exceeds 14 bytes")
        return name
    }

    // App-launch prelude (sid 0x01) - must be sent verbatim once per BLE session.
    static let prelude: [UInt8] = [
        0xAA, 0x21, 0x92, 0x13, 0x01, 0x01, 0x01, 0x20, 0x08, 0x02, 0x10, 0x9C,
        0x01, 0x22, 0x0A, 0x1A, 0x08, 0x12, 0x06, 0x12, 0x04, 0x08, 0x00, 0x10,
        0x00, 0xA1, 0x42,
    ]

    // ---- proto3 wire encoders (omit zero/empty scalars, like protobuf-es) ----
    private static func varint(_ value: Int) -> [UInt8] {
        var u = UInt(value), out = [UInt8]()
        repeat { var b = UInt8(u & 0x7F); u >>= 7; if u != 0 { b |= 0x80 }; out.append(b) } while u != 0
        return out
    }
    private static func tag(_ field: Int, _ wire: Int) -> [UInt8] { varint((field << 3) | wire) }
    private static func uintF(_ field: Int, _ v: Int) -> [UInt8] { v == 0 ? [] : tag(field, 0) + varint(v) }
    private static func strF(_ field: Int, _ s: String) -> [UInt8] {
        let b = Array(s.utf8); return b.isEmpty ? [] : tag(field, 2) + varint(b.count) + b
    }
    private static func bytesF(_ field: Int, _ b: [UInt8]) -> [UInt8] {
        b.isEmpty ? [] : tag(field, 2) + varint(b.count) + b
    }
    /// Nested message - always emitted (the field is "present").
    private static func msgF(_ field: Int, _ content: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(content.count) + content
    }

    // ---- message builders (return the inner protobuf payload) ---------------

    /// Cmd=12 heartbeat. Keeps the EvenHub plugin task alive (~1.5s cadence).
    static func heartbeat(magic: Int = 205) -> [UInt8] {
        uintF(1, Cmd.heartbeat) + uintF(2, magic) + msgF(14, /* HeartBeatPacket{Cnt:0} */ [])
    }

    struct ImageContainer { let id: Int; let name: String; let x, y, w, h: Int }

    /// Cmd=0 create startup page declaring image container(s) directly - primes
    /// the plugin task AND declares the image surface(s), with NO visible list
    /// menu (up to 4 image containers = the 2×2 full-lens grid).
    static func createStartupPageImages(_ containers: [ImageContainer], magic: Int = 201) -> [UInt8] {
        var create = uintF(1, containers.count)
        for c in containers {
            let obj = uintF(1, c.x) + uintF(2, c.y) + uintF(3, c.w) + uintF(4, c.h)
                    + uintF(5, c.id) + strF(6, c.name)
            create += msgF(4, obj)                                   // ImageObject (repeated)
        }
        create += uintF(5, 10000)                                    // widgetId
        return uintF(1, Cmd.create) + uintF(2, magic) + msgF(3, create)
    }

    /// Cmd=3 one image-data fragment.
    static func imageRawData(containerId: Int, name: String, sessionId: Int, totalSize: Int,
                             fragmentIndex: Int, data: [UInt8], magic: Int) -> [UInt8] {
        let img = uintF(1, containerId) + strF(2, name) + uintF(3, sessionId) + uintF(4, totalSize)
                + uintF(6, fragmentIndex) + uintF(7, data.count) + bytesF(8, data)  // CompressMode(5)=0 omitted
        return uintF(1, Cmd.updateImage) + uintF(2, magic) + msgF(5, img)
    }

    // ---- native list / text container builders ------------------------------
    //
    // Field numbers verified against ble/gen/EvenHub_pb.ts (see PROTOCOL.md §9a):
    //   ListContainerProperty: X=1,Y=2,W=3,H=4,...,ContainerID=9,ContainerName=10,
    //                          ItemContainer=11,IsEventCapture=12.
    //   List_ItemContainerProperty: ItemCount=1,ItemWidth=2,IsItemSelectBorderEn=3,ItemName(repeated)=4.
    //   TextContainerProperty: X=1,Y=2,W=3,H=4,...,ContainerID=9,ContainerName=10,IsEventCapture=11,Content=12.
    //   CreateStartUpPageContainer: ContainerTotalNum=1,ListObject=2,TextObject=3,ImageObject=4,widgetId=5.
    //   RebuildPageContainer: ContainerTotalNum=1,ListObject=2,TextObject=3,ImageObject=4.
    //   TextContainerUpgrade: ContainerID=1,ContainerName=2,ContentOffset=3,ContentLength=4,Content=5.
    //   Wrapper: CreateMessage=3, RebuildContainer=7, TextUpgrade=9, ShutDownCmd=11.

    struct ListGeom { var x = 0, y = 0, w = 576, h = 288 }

    /// repeated string: one (field<<3|2)+len+bytes per non-empty item, in order.
    private static func repStrF(_ field: Int, _ items: [String]) -> [UInt8] {
        items.flatMap { strF(field, $0) }
    }

    /// List_ItemContainerProperty payload (the inner rows).
    /// NEVER pass an empty-string row - strF drops it and ItemCount would mismatch.
    private static func listItemObj(items: [String], selectBorder: Bool) -> [UInt8] {
        let safe = items.map { $0.isEmpty ? "·" : $0 }
        return uintF(1, safe.count)                      // ItemCount
             + uintF(3, selectBorder ? 1 : 0)            // IsItemSelectBorderEn
             + repStrF(4, safe)                          // ItemName (repeated)
    }

    private static func listObj(id: Int, name: String, items: [String], capture: Bool,
                                selectBorder: Bool, geom: ListGeom) -> [UInt8] {
        let item = listItemObj(items: items, selectBorder: selectBorder)
        return uintF(1, geom.x) + uintF(2, geom.y) + uintF(3, geom.w) + uintF(4, geom.h)
             + uintF(9, id) + strF(10, validName(name)) + msgF(11, item)
             + uintF(12, capture ? 1 : 0)
    }

    private static func textObj(id: Int, name: String, content: String, capture: Bool,
                                geom: ListGeom) -> [UInt8] {
        return uintF(1, geom.x) + uintF(2, geom.y) + uintF(3, geom.w) + uintF(4, geom.h)
             + uintF(9, id) + strF(10, validName(name)) + uintF(11, capture ? 1 : 0)
             + strF(12, content)
    }

    /// Cmd=0 CREATE a startup page with ONE full-lens LIST container. Full-lens
    /// 576×288 so the HUD fills the screen. Do NOT co-declare a second/overlapping
    /// container or a TextObject here - that causes ID collision / createInvalid.
    /// The single container is rebuilt in place (Cmd=7) to flip list↔text.
    static func createList(name: String, items: [String], extraNames: [String] = [],
                           geom: ListGeom = .init(),
                           containerId: Int = 1, widgetId: Int = 10000,
                           selectBorder: Bool = true, captureEvents: Bool = true,
                           magic: Int = 201) -> [UInt8] {
        var create = uintF(1, 1 + extraNames.count)      // ContainerTotalNum
        create += msgF(2, listObj(id: containerId, name: name, items: items,
                                  capture: captureEvents, selectBorder: selectBorder, geom: geom))
        for (i, en) in extraNames.enumerated() {
            create += msgF(2, listObj(id: 2 + i, name: en, items: ["."], capture: false,
                                      selectBorder: false, geom: geom))
        }
        create += uintF(5, widgetId)
        return uintF(1, Cmd.create) + uintF(2, magic) + msgF(3, create)
    }

    /// Cmd=7 REBUILD an existing LIST container (same name) with new rows.
    static func rebuildList(name: String, items: [String], geom: ListGeom = .init(),
                            containerId: Int = 1, selectBorder: Bool = true,
                            captureEvents: Bool = true, magic: Int) -> [UInt8] {
        let obj = listObj(id: containerId, name: name, items: items,
                          capture: captureEvents, selectBorder: selectBorder, geom: geom)
        let rebuild = uintF(1, 1) + msgF(2, obj)         // ContainerTotalNum, ListObject
        return uintF(1, Cmd.rebuild) + uintF(2, magic) + msgF(7, rebuild)
    }

    /// Cmd=7 create/switch a TEXT container (same or new name) with content.
    static func rebuildText(name: String, content: String, geom: ListGeom = .init(),
                            containerId: Int = 1, captureEvents: Bool = true,
                            magic: Int) -> [UInt8] {
        let obj = textObj(id: containerId, name: name, content: content,
                          capture: captureEvents, geom: geom)
        let rebuild = uintF(1, 1) + msgF(3, obj)         // ContainerTotalNum, TextObject=3
        return uintF(1, Cmd.rebuild) + uintF(2, magic) + msgF(7, rebuild)
    }

    /// Cmd=5 in-place TEXT upgrade (flicker-free, cheapest path). Replaces from
    /// offset 0 with `content` (full snapshot, <= ~1000 bytes).
    static func textUpgrade(containerId: Int = 1, name: String, content: String,
                            magic: Int) -> [UInt8] {
        let bytes = Array((content.isEmpty ? "·" : content).utf8)   // length-0 would be dropped
        let up = uintF(1, containerId) + strF(2, validName(name)) + uintF(3, 0)
               + uintF(4, bytes.count) + bytesF(5, bytes)
        return uintF(1, Cmd.updateText) + uintF(2, magic) + msgF(9, up)   // TextUpgrade=9
    }

    // ---- multi-container page builders --------------------------------------
    //
    // Compose the lens from SEVERAL containers at once (text + list). Encoding
    // reuses the EXACT proven field layout (geom 1-4, chrome 5-8, id 9, name 10,
    // capture/content 11/12). Container chrome fields 5-8: borderWidth=5,
    // borderColor=6, borderRadius=7, paddingLength=8.

    struct TextProp {
        var id: Int; var name: String
        var x = 0, y = 0, w = 576, h = 288
        var borderWidth = 0, borderColor = 5, borderRadius = 0, padding = 0
        var capture = false
        var content = ""
    }
    struct ListProp {
        var id: Int; var name: String
        var x = 0, y = 0, w = 576, h = 288
        var borderWidth = 0, borderColor = 5, borderRadius = 0, padding = 0
        var capture = true
        var selectBorder = true
        var items: [String]
    }

    private static func textObjFull(_ t: TextProp) -> [UInt8] {
        uintF(1, t.x) + uintF(2, t.y) + uintF(3, t.w) + uintF(4, t.h)
            + uintF(5, t.borderWidth) + uintF(6, t.borderColor) + uintF(7, t.borderRadius) + uintF(8, t.padding)
            + uintF(9, t.id) + strF(10, validName(t.name))
            + uintF(11, t.capture ? 1 : 0) + strF(12, t.content)
    }
    private static func listObjFull(_ l: ListProp) -> [UInt8] {
        let item = listItemObj(items: l.items, selectBorder: l.selectBorder)
        return uintF(1, l.x) + uintF(2, l.y) + uintF(3, l.w) + uintF(4, l.h)
            + uintF(5, l.borderWidth) + uintF(6, l.borderColor) + uintF(7, l.borderRadius) + uintF(8, l.padding)
            + uintF(9, l.id) + strF(10, validName(l.name)) + msgF(11, item)
            + uintF(12, l.capture ? 1 : 0)
    }

    /// Cmd=0 CREATE a startup page from several text + list containers at once.
    /// ListObject=2, TextObject=3 (repeated), widgetId=5 (CreateStartUpPageContainer).
    static func createPage(texts: [TextProp], lists: [ListProp] = [],
                           widgetId: Int = 10000, magic: Int = 201) -> [UInt8] {
        var create = uintF(1, texts.count + lists.count)        // ContainerTotalNum
        for l in lists { create += msgF(2, listObjFull(l)) }     // ListObject (repeated)
        for t in texts { create += msgF(3, textObjFull(t)) }     // TextObject (repeated)
        create += uintF(5, widgetId)
        return uintF(1, Cmd.create) + uintF(2, magic) + msgF(3, create)
    }

    /// Cmd=7 REBUILD the whole page from several text + list containers (family
    /// switch). RebuildPageContainer: ContainerTotalNum=1, ListObject=2, TextObject=3.
    static func rebuildPage(texts: [TextProp], lists: [ListProp] = [], magic: Int) -> [UInt8] {
        var rb = uintF(1, texts.count + lists.count)             // ContainerTotalNum
        for l in lists { rb += msgF(2, listObjFull(l)) }
        for t in texts { rb += msgF(3, textObjFull(t)) }
        return uintF(1, Cmd.rebuild) + uintF(2, magic) + msgF(7, rb)
    }

    /// Cmd=9 ShutDown the foregrounded page (frees its containers). No name field.
    static func shutDown(exitMode: Int = 0, magic: Int) -> [UInt8] {
        uintF(1, Cmd.shutdown) + uintF(2, magic) + msgF(11, uintF(1, exitMode))  // ShutDownCmd=11
    }

    // ---- incoming async event parser ----------------------------------------
    //
    // Async events arrive as the wrapper Cmd(1)==2 (OS_NOTIFY_EVENT_TO_APP) with
    // DevEvent(13)=SendDeviceEvent { ListEvent=1, TextEvent=2, SysEvent=3 }, OR
    // Cmd(1)==11 (OS_PRIVATE_EVENT) with DevPrivateEvent(16).
    //   List_ItemEvent: ContainerID=1, ContainerName=2, CurrentSelectItemName=3,
    //                   CurrentSelectItemIndex=4, EventType=5.
    //   Text_ItemEvent: ContainerID=1, ContainerName=2, EventType=3.
    //   Sys_ItemEvent:  EventType=1, EventSource=2, IMUData=3, systemExitReasonCode=4.
    // OsEventTypeList: CLICK=0, SCROLL_TOP=1, SCROLL_BOTTOM=2, DOUBLE_CLICK=3,
    //                  FOREGROUND_ENTER=4, FOREGROUND_EXIT=5, ABNORMAL_EXIT=6,
    //                  SYSTEM_EXIT=7, IMU_DATA_REPORT=8.
    enum InEvent {
        case listClick(name: String, index: Int, itemName: String, type: Int)
        case textClick(name: String, type: Int)
        case sysEvent(type: Int, exitReason: Int)
        case privateEvent(name: String, eventId: Int, eventData: Int)
        case other
    }

    private static func readStr(_ b: [UInt8], _ off: Int, _ len: Int) -> String {
        let end = min(off + len, b.count)
        return String(bytes: b[off..<end], encoding: .utf8) ?? ""
    }

    /// Parse the inner List_ItemEvent payload.
    private static func parseListEvent(_ b: [UInt8]) -> InEvent {
        var name = "", item = "", index = 0, type = 0
        var i = 0
        while i < b.count {
            let key = Int(b[i]); i += 1
            let f = key >> 3, w = key & 7
            if w == 0 { let (v, n) = dVarint(b, i); i = n
                if f == 4 { index = v } else if f == 5 { type = v } }
            else if w == 2 { let (l, n) = dVarint(b, i); i = n
                if f == 2 { name = readStr(b, i, l) } else if f == 3 { item = readStr(b, i, l) }
                i += l }
            else { break }
        }
        return .listClick(name: name, index: index, itemName: item, type: type)
    }

    private static func parseTextEvent(_ b: [UInt8]) -> InEvent {
        var name = "", type = 0
        var i = 0
        while i < b.count {
            let key = Int(b[i]); i += 1
            let f = key >> 3, w = key & 7
            if w == 0 { let (v, n) = dVarint(b, i); i = n; if f == 3 { type = v } }
            else if w == 2 { let (l, n) = dVarint(b, i); i = n; if f == 2 { name = readStr(b, i, l) }; i += l }
            else { break }
        }
        return .textClick(name: name, type: type)
    }

    private static func parseSysEvent(_ b: [UInt8]) -> InEvent {
        var type = 0, exitReason = 0
        var i = 0
        while i < b.count {
            let key = Int(b[i]); i += 1
            let f = key >> 3, w = key & 7
            if w == 0 { let (v, n) = dVarint(b, i); i = n
                if f == 1 { type = v } else if f == 4 { exitReason = v } }
            else if w == 2 { let (l, n) = dVarint(b, i); i = n + l }
            else { break }
        }
        return .sysEvent(type: type, exitReason: exitReason)
    }

    /// Descend SendDeviceEvent (DevEvent field 13).
    private static func parseDevEvent(_ b: [UInt8]) -> InEvent {
        var i = 0
        while i < b.count {
            let key = Int(b[i]); i += 1
            let f = key >> 3, w = key & 7
            if w == 2 { let (l, n) = dVarint(b, i); i = n
                let sub = Array(b[i..<min(i + l, b.count)]); i += l
                if f == 1 { return parseListEvent(sub) }
                if f == 2 { return parseTextEvent(sub) }
                if f == 3 { return parseSysEvent(sub) }
            } else if w == 0 { let (_, n) = dVarint(b, i); i = n }
            else { break }
        }
        return .other
    }

    /// Descend CommonDevicePrivateEvent (DevPrivateEvent field 16):
    /// ContainerID=1, ContainerName=2, eventId=3, eventData=4.
    private static func parsePrivate(_ b: [UInt8]) -> InEvent {
        var name = "", eventId = 0, eventData = 0
        var i = 0
        while i < b.count {
            let key = Int(b[i]); i += 1
            let f = key >> 3, w = key & 7
            if w == 0 { let (v, n) = dVarint(b, i); i = n
                if f == 3 { eventId = v } else if f == 4 { eventData = v } }
            else if w == 2 { let (l, n) = dVarint(b, i); i = n; if f == 2 { name = readStr(b, i, l) }; i += l }
            else { break }
        }
        return .privateEvent(name: name, eventId: eventId, eventData: eventData)
    }

    private static func parseEventInner(_ pb: [UInt8]) -> InEvent? {
        var cmd = -1
        var devSub: [UInt8]? = nil
        var privSub: [UInt8]? = nil
        var i = 0
        while i < pb.count {
            let key = Int(pb[i]); i += 1
            let f = key >> 3, w = key & 7
            if w == 0 { let (v, n) = dVarint(pb, i); i = n; if f == 1 { cmd = v } }
            else if w == 2 {
                let (l, n) = dVarint(pb, i); i = n
                let sub = Array(pb[i..<min(i + l, pb.count)]); i += l
                if f == 13 { devSub = sub } else if f == 16 { privSub = sub }
            } else { break }
        }
        if cmd == Cmd.event, let d = devSub { return parseDevEvent(d) }
        if cmd == Cmd.privateEvent, let p = privSub { return parsePrivate(p) }
        return nil
    }

    /// Parse an EvenHub async event body. The sliced payload may carry a trailing
    /// CRC, so retry with the last 2 bytes dropped.
    static func parseEvent(_ pb: [UInt8]) -> InEvent? {
        if let e = parseEventInner(pb) { return e }
        if pb.count > 2 { return parseEventInner(Array(pb.dropLast(2))) }
        return nil
    }

    // ---- response decoding (so we can see WHY the firmware rejects) ---------
    private static func dVarint(_ b: [UInt8], _ off: Int) -> (Int, Int) {
        var v = 0, s = 0, i = off
        while i < b.count { let c = Int(b[i]); i += 1; v |= (c & 0x7F) << s; if c & 0x80 == 0 { break }; s += 7 }
        return (v, i)
    }
    private static func errName(_ e: Int) -> String {
        let m = [0: "createOK", 1: "createInvalid", 2: "createOversize", 3: "createOOM",
                 4: "imageOK", 5: "imageFAILED", 6: "rebuildOK", 7: "rebuildFAILED",
                 8: "textOK", 9: "textFailed", 12: "heartbeatOK"]
        return m[e] ?? "err\(e)"
    }
    private static func cmdName(_ c: Int) -> String {
        let m = [1: "createResp", 2: "event", 4: "imageResp", 6: "textResp",
                 8: "rebuildResp", 13: "heartbeatResp"]
        return m[c] ?? "cmd\(c)"
    }
    struct Response { let cmd: Int; let magic: Int; let result: Int? }

    /// Parse an EvenHub (sid 0xE0) response payload into cmd / magic / result.
    static func parseResponse(_ pb: [UInt8]) -> Response {
        var cmd = -1, magic = -1, result: Int? = nil
        var i = 0
        while i < pb.count {
            let key = Int(pb[i]); i += 1
            let field = key >> 3, wire = key & 7
            if wire == 0 {
                let (v, n) = dVarint(pb, i); i = n
                if field == 1 { cmd = v } else if field == 2 { magic = v }
            } else if wire == 2 {
                let (len, n) = dVarint(pb, i); i = n
                let endIdx = min(i + len, pb.count)
                let sub = Array(pb[i..<endIdx]); i = endIdx
                // Response messages put the error enum in field 1 (ResCmdMsg) or 8 (ErrorCode).
                var j = 0
                while j < sub.count {
                    let k = Int(sub[j]); j += 1
                    let f = k >> 3, w = k & 7
                    if w == 0 { let (vv, nn) = dVarint(sub, j); j = nn; if f == 1 || f == 8 { result = vv } }
                    else if w == 2 { let (l, nn) = dVarint(sub, j); j = nn + l }
                    else { break }
                }
            } else { break }
        }
        return Response(cmd: cmd, magic: magic, result: result)
    }

    static func describeResponse(_ pb: [UInt8]) -> String {
        let r = parseResponse(pb)
        return "EvenHub \(cmdName(r.cmd)) magic=\(r.magic) \(r.result.map { "result=\(errName($0))" } ?? "")"
    }

    // ---- 4-bpp BMP builder (port of buildEvenHubBmp) ------------------------
    /// `pixel(x,y)` returns 0..15 (0=off, 15=bright). Bottom-up, 4-byte stride.
    static func bmp4(width: Int, height: Int, pixel: (Int, Int) -> Int) -> [UInt8] {
        let bytesPerPixelRow = (width + 1) / 2
        let rowStride = (bytesPerPixelRow + 3) & ~3
        let pixelDataSize = rowStride * height
        let pixelOffset = 14 + 40 + 64
        let fileSize = pixelOffset + pixelDataSize
        var b = [UInt8](repeating: 0, count: fileSize)
        func u16(_ off: Int, _ v: Int) { b[off] = UInt8(v & 0xFF); b[off+1] = UInt8((v >> 8) & 0xFF) }
        func u32(_ off: Int, _ v: Int) { b[off] = UInt8(v & 0xFF); b[off+1] = UInt8((v >> 8) & 0xFF); b[off+2] = UInt8((v >> 16) & 0xFF); b[off+3] = UInt8((v >> 24) & 0xFF) }
        b[0] = 0x42; b[1] = 0x4D
        u32(2, fileSize); u32(10, pixelOffset)
        u32(14, 40); u32(18, width); u32(22, height); u16(26, 1); u16(28, 4)
        u32(34, pixelDataSize); u32(46, 16)
        for i in 0..<16 { let v = i * 17; let p = 54 + i * 4; b[p] = UInt8(v); b[p+1] = UInt8(v); b[p+2] = UInt8(v) }
        for bmpRow in 0..<height {
            let srcY = height - 1 - bmpRow
            let rowOff = pixelOffset + bmpRow * rowStride
            var x = 0
            while x < width {
                let hi = pixel(x, srcY) & 0x0F
                let lo = (x + 1 < width ? pixel(x + 1, srcY) : 0) & 0x0F
                b[rowOff + (x >> 1)] = UInt8((hi << 4) | lo)
                x += 2
            }
        }
        return b
    }

    /// Render a CoreGraphics drawing (white = bright) into a 4-bpp EvenHub BMP.
    static func bmp4(width: Int, height: Int, draw: (CGContext) -> Void) -> [UInt8] {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setFillColor(gray: 1, alpha: 1)
        draw(ctx)
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        return bmp4(width: width, height: height) { x, y in Int(buf[y * width + x]) >> 4 }
    }

    struct Tile { let x, y: Int; let bmp: [UInt8] }

    /// Render a full `fullW×fullH` drawing once, then slice into `tileW×tileH`
    /// gray4 tiles (reading order: TL, TR, BL, BR) for the 2×2 lens grid.
    static func renderTiles(fullW: Int, fullH: Int, tileW: Int, tileH: Int,
                            draw: (CGContext) -> Void) -> [Tile] {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: fullW, height: fullH, bitsPerComponent: 8,
                                  bytesPerRow: fullW, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))
        ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setFillColor(gray: 1, alpha: 1)
        draw(ctx)
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var tiles: [Tile] = []
        var ty = 0
        while ty < fullH {
            var tx = 0
            while tx < fullW {
                let ox = tx, oy = ty
                let bmp = bmp4(width: tileW, height: tileH) { lx, ly in
                    let gx = ox + lx, gy = oy + ly
                    return (gx < fullW && gy < fullH) ? Int(buf[gy * fullW + gx]) >> 4 : 0
                }
                tiles.append(Tile(x: tx, y: ty, bmp: bmp))
                tx += tileW
            }
            ty += tileH
        }
        return tiles
    }

    /// Draw a left-aligned text line. `yTop` is measured from the TOP of the
    /// canvas (in pixels); the context is y-up so we convert. Monospace.
    static func drawText(_ ctx: CGContext, _ s: String, x: CGFloat, yTop: CGFloat,
                         size: CGFloat, canvasHeight: CGFloat) {
        guard !s.isEmpty else { return }
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .init(rawValue: kCTFontAttributeName as String): font,
            .init(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = CGPoint(x: x, y: canvasHeight - yTop - size)
        CTLineDraw(line, ctx)
    }
}

# g2-bridge - iOS

A minimal SwiftUI iPhone app that drives **Even Realities G2** smart glasses
directly over BLE (no Even app) and exposes a tiny **local HTTP server**
so anything on your Wi-Fi can stream text or images to the lens.

```
your code / curl / home automation  ──HTTP──▶  iPhone (this app)  ──BLE──▶  G2 glasses
```

The BLE core is a faithful port of a protocol implementation **verified against
real G2 hardware**. The app shell and HTTP server around it are new. See
[`../PROTOCOL.md`](../PROTOCOL.md) for the wire protocol (the source of truth).

> [!NOTE]
> **Tested and working on real G2 glasses.** This app compiles and drives the lens
> on-device. You only need to set your own signing Team in Xcode (below);
> CoreBluetooth requires a physical iPhone (the Simulator has no BLE).

---

## What's in here

```
ios/
├── project.yml                    # XcodeGen project spec (iOS 16+ app target)
├── Info.plist                     # permission strings (BLE + Local Network)
└── Sources/
    ├── G2Bridge/                  # the reusable core (no UI)
    │   ├── CRC16.swift            # CRC-16/CCITT-FALSE (verbatim port)
    │   ├── G2Protocol.swift       # framing, auth, teleprompter text (verbatim)
    │   ├── EvenHub.swift          # native containers + 4-bpp BMP image protocol
    │   ├── G2Connection.swift     # dual-arm CoreBluetooth manager + public API
    │   ├── GlassImage.swift       # a test-pattern bitmap (smoke test)
    │   └── BridgeServer.swift     # the local HTTP/1.1 server
    └── G2BridgeApp/               # the SwiftUI app shell
        ├── G2BridgeApp.swift      # @main - owns G2Connection + BridgeServer
        └── ContentView.swift      # one-screen UI
```

The **mic / LC3 audio** path from the source implementation is intentionally
omitted in v1 (optional per the spec).

---

## Public API (`G2Connection`)

`G2Connection` is an `ObservableObject`. All display methods are `@MainActor async`.

| Method | What it does |
|--------|--------------|
| `connect()` | Scan/adopt both arms, authenticate, start the heartbeat. |
| `disconnect()` | Tear down both arms. |
| `displayText(_:)` | Render text via the **teleprompter** flow (wraps to 25×10, auto-refreshes). |
| `showText(name:content:)` | Switch the native container to a TEXT shape with content (Cmd=7). |
| `updateText(name:content:)` | Flicker-free in-place text update on the native container (Cmd=5). |
| `displayList(name:rows:)` | Show/rebuild a native tappable LIST (Cmd=7). |
| `displayImage(_:)` | Stream a single 288×144 4-bpp BMP into the top-left tile. |
| `displayComponent(_ draw:)` | Render a full-lens 576×288 CoreGraphics drawing as a 2×2 tile grid. |
| `@Published status` / `detail` | `G2Status` (`disconnected`/`scanning`/…/`ready`/`error`) + a detail string. |

Optional tap callbacks: `onListTap`, `onTextTap`, `onPageEvent`, `onDoubleTap`.

---

## HTTP endpoints (`BridgeServer`, port 8080)

| Method / path | Body | Effect |
|---------------|------|--------|
| `POST /text`  | `{"text":"..."}` (or `text/plain`) | `G2Connection.displayText` - teleprompter render. |
| `POST /image` | raw PNG or JPEG | Decode → draw into a 576×288 grayscale canvas (fit/letterboxed) → `displayComponent` (tiles 2×2). |
| `GET /status` | - | `{"status":"...","detail":"..."}` |
| `GET /`       | - | one-line help string |

**Why `/text` uses `displayText` (teleprompter) and not `updateText`:** the
teleprompter path renders arbitrary text out of the box with no pre-created
container and self-refreshes, which is the simplest thing that reliably renders.
If you want flicker-free in-place updates instead, call `g2.updateText(name:"hud",
content:…)` (it auto-creates the native container on first use) - swap the one
line in `BridgeServer.handle`'s `POST /text` case.

**Server limits (by design):** HTTP/1.1 with `Connection: close` (one
request/response per socket, no keep-alive/pipelining); the whole request is
buffered in memory with a 4 MB body cap (413 over that); only the request line,
`Content-Length`, and `Content-Type` are parsed (no chunked transfer-encoding -
send a `Content-Length`, which `curl` and `URLSession` do by default); no TLS,
no auth - bind it to a trusted LAN only.

---

## Build & run

### Option A - XcodeGen (recommended)

```sh
brew install xcodegen          # if you don't have it
cd ios
xcodegen generate              # creates G2Bridge.xcodeproj from project.yml
open G2Bridge.xcodeproj
```

In Xcode: select the **G2Bridge** target → **Signing & Capabilities** → set your
Team. Pick your iPhone as the run destination and **Run** (CoreBluetooth needs a
real device; the Simulator has no BLE).

### Option B - manual (no XcodeGen)

1. Xcode → **File ▸ New ▸ Project ▸ iOS ▸ App** (SwiftUI lifecycle, Swift).
   Delete the generated `ContentView.swift` and `<App>.swift`.
2. Drag **all** files under `Sources/G2Bridge/` and `Sources/G2BridgeApp/`
   into the project ("Copy items if needed", add to the app target).
3. Set the deployment target to **iOS 16.0** or later.
4. Open the target's **Info** tab (or its generated Info.plist) and add the three
   keys from [`Info.plist`](Info.plist):
   - `NSBluetoothAlwaysUsageDescription`
   - `NSLocalNetworkUsageDescription`
   - `NSBonjourServices` → one item `_g2bridge._tcp` (optional but recommended)
5. Run on a physical iPhone.

No third-party dependencies - everything is SDK framework code (CoreBluetooth,
Network, CoreGraphics, CoreText, ImageIO, SwiftUI).

---

## Pair the glasses

1. The G2 is **two BLE peripherals** (left + right arm). You do **not** pair them
   in iOS Settings - leave them out of Settings ▸ Bluetooth if possible. This app
   scans for and connects both arms itself.
   - If an arm is already "Connected" in iOS Settings (e.g. from the Even app),
     the app adopts it via `retrieveConnectedPeripherals` (a scan won't surface an
     already-connected peripheral) and scans only for the missing arm.
2. Wake the glasses (wear them / open the case) so they advertise as `Even G2_L_…`
   / `Even G2_R_…`.
3. Tap **Connect**. Watch the status go `scanning → connecting → authenticating →
   ready`. Both arms must be found within ~20 s or you get a scan timeout.

---

## Test it (`curl`)

With the phone on Wi-Fi and **ready**, the UI shows `http://<phone-ip>:8080`.

```sh
PHONE=192.168.1.42          # the IP shown in the app

curl "http://$PHONE:8080/status"

curl -X POST "http://$PHONE:8080/text" \
     -H 'Content-Type: application/json' \
     -d '{"text":"hello from the network"}'

curl -X POST "http://$PHONE:8080/image" \
     -H 'Content-Type: image/png' \
     --data-binary @picture.png
```

A quick on-device smoke test without the network: tap **Send to lens** in the UI,
or call `await g2.displayImage(GlassImage.testPattern())` from code.

---

## iOS Local Network permission gotchas

- The **first inbound** LAN connection triggers the *"… would like to find and
  connect to devices on your local network"* prompt. **You must tap Allow** or the
  HTTP server accepts the socket but the OS drops the traffic - symptom: `curl`
  hangs or connection-resets while `/status` never answers. If you tapped Don't
  Allow, re-enable it in **Settings ▸ Privacy & Security ▸ Local Network ▸
  g2-bridge**.
- Local Network permission is **not** requested until something actually uses the
  LAN. The app starts the listener on first launch; the prompt appears on the
  first request. If you never see the prompt, send one request to trigger it.
- The phone and the client must be on the **same Wi-Fi/subnet**. Cellular won't
  work; many "guest" Wi-Fi networks block client-to-client traffic.
- `en0` is assumed to be Wi-Fi (true on iPhone). If the displayed IP is `-`,
  you're not on Wi-Fi - connect to Wi-Fi and tap **Refresh IP / restart server**.

---

## First run

After setting your signing Team, a quick sanity pass:

1. **It builds & launches** on a physical iPhone (the Simulator has no BLE).
2. **BLE connects.** `connect()` reaches `ready` with both arms (check the Xcode
   console - the manager logs every GATT char and packet).
3. **Text renders.** `POST /text` (or the UI Send button) shows on the lens.
4. **Image renders.** `await g2.displayImage(GlassImage.testPattern())` first
   (single tile), then `POST /image` (full-lens 2×2). The firmware silently drops
   the *first* image burst after a CREATE - the code already sends a sacrificial
   warmup stream, so the real frame should land on the same call.
5. **Local Network prompt.** Confirm you got the Allow prompt and that `curl`
   from another machine reaches `/status`.
6. **Permission strings present.** If the app crashes on launch with a
   `TCC`/usage-description message, a required Info.plist key is missing.
```

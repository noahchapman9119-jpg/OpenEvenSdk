# g2-bridge - Android

The Android build of the g2-bridge: a Kotlin/Compose app that drives Even
Realities **G2** smart glasses **directly over BLE** (no Even app) and
runs a tiny local HTTP server so anything on your network can push text or images
to the lens.

It is a faithful port of the iOS bridge / the verified protocol layer.
The wire protocol is the shared [`../PROTOCOL.md`](../PROTOCOL.md).

> ## ⚠️ NOT device/Gradle-tested in this repo - verify first
> This module was written **without an Android toolchain or G2 glasses in the
> build environment**. It has **not been Gradle-synced, compiled, or run on a
> device**. The BLE protocol bytes are a byte-for-byte port of a verified-working
> implementation, but the app shell (Gradle wiring, BLE callbacks, NanoHTTPD
> integration) needs a first-run pass on your machine. **Verify, in order:**
>
> 1. **Gradle sync / build** in Android Studio (resolve any dependency-version
>    drift - the Compose BOM, AGP, and Kotlin versions are pinned but may need a
>    bump for your installed Android Studio / JDK 17).
> 2. **Runtime permissions** are actually granted (Android 12+ BLE model - see
>    below). A denied `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` silently breaks scan.
> 3. **Dual-arm scan + connect** finds BOTH arms (`Even …_L_…` / `…_R_…`) and the
>    7-packet auth completes (status goes to `ready`).
> 4. **Teleprompter text** renders (`POST /text`) and **image streaming**
>    (`POST /image`) paints all four tiles. Watch Logcat tag `G2` for the BLE
>    handshake, acks, and any reassembly aborts.
> 5. **BLE write pacing** is correct on your phone's stack - see "Flow control"
>    below; if you see dropped image fragments, the single-outstanding-write
>    serialization may need tuning (timeout in `performWrite`).

## What it does

- Connects to the G2's **two BLE peripherals** (left + right arm). Text /
  teleprompter is mirrored to **both** arms; EvenHub (native containers, images)
  goes to the **right arm only** - per the protocol.
- Runs the 7-packet auth, a 1.5 s keep-alive heartbeat, the teleprompter text
  flow, and the EvenHub 4-bpp BMP image streamer (2×2 tile grid, sliding-window
  acks, session-jump recovery).
- Exposes a local HTTP server on **port 8080** so any device on your LAN can
  stream to the glasses.

## Build / run

**Android Studio** (recommended):
1. Open the `android/` folder as a project (it has its own Gradle root).
2. Let it sync. JDK 17 is required (`compileSdk 34`, AGP 8.5).
3. Run the `app` configuration on a physical device (BLE does not work on the
   emulator). `minSdk 26` (Android 8.0).

**Command line:**
```bash
cd android
./gradlew :app:assembleDebug          # or installDebug to push to a device
```
> A Gradle wrapper (`gradlew` + `gradle/wrapper/…`) is **not** checked in. Open
> the project in Android Studio once (it generates the wrapper), or run
> `gradle wrapper --gradle-version 8.7` with a local Gradle install.

## Pair the glasses

You do **not** need the Even app. Power on the glasses near the phone and press
**Connect** in the app - it scans for peripherals whose name contains `Even`,
classifies them left/right by name, connects both, and authenticates.

If an arm is already bonded/connected in Android's Bluetooth settings, the app
adopts that connection first (a connected device is not returned by a fresh
scan), then scans only for the missing arm.

## Grant permissions

On first launch the app requests the BLE runtime permissions. **Android 12+ (API
31+) BLE permission model:**

- `BLUETOOTH_SCAN` (declared `neverForLocation` - we do not derive location).
- `BLUETOOTH_CONNECT`.
- `POST_NOTIFICATIONS` (Android 13+) for the foreground-service notification.

**Pre-Android-12 (API 26-30):** `BLUETOOTH`, `BLUETOOTH_ADMIN`, and
`ACCESS_FINE_LOCATION` (a BLE scan legally requires location permission on those
versions). The manifest declares both sets; the app requests the right ones at
runtime for the OS version.

The BLE link + HTTP server run in a **foreground service**
(`foregroundServiceType=connectedDevice`) so they survive backgrounding, with a
persistent notification showing the connection status and the server URL.

## HTTP API

The app shows the server URL (`http://<wifi-ip>:8080`) on screen. Endpoints:

| Method | Path      | Body                       | Effect |
|--------|-----------|----------------------------|--------|
| `POST` | `/text`   | JSON `{"text":"hello"}` (or raw text) | Teleprompter text to both arms |
| `POST` | `/image`  | raw PNG/JPEG bytes         | Decode → scale to 576×288 → 2×2 tile grid to the lens |
| `GET`  | `/status` | -                          | JSON `{"status","detail"}` |
| `GET`  | `/`       | -                          | Human-readable help page |

**Test with curl:**
```bash
# Text
curl -X POST http://<phone-ip>:8080/text \
     -H "Content-Type: application/json" \
     -d '{"text":"hello from curl"}'

# Image (raw body)
curl -X POST http://<phone-ip>:8080/image \
     -H "Content-Type: image/png" \
     --data-binary @picture.png

# Status
curl http://<phone-ip>:8080/status
```

## Flow control (the key Android difference vs iOS)

iOS CoreBluetooth exposes `canSendWriteWithoutResponse`, so the iOS bridge drains
writes at the radio's pace. **Android's `BluetoothGatt` has no such signal** and
instead requires that writes be **serialized** - only one write may be
outstanding, and the next must wait for `onCharacteristicWrite`. So this port
funnels **every** GATT write (both arms) through a single suspending command
queue (`writeQueue` / `writeLoop` in `G2Connection.kt`) that waits for
`onCharacteristicWrite` (with a short timeout fallback) before sending the next
frame. That both satisfies the one-outstanding-write rule and applies the
backpressure that prevents the firmware's image-reassembly buffers from
overflowing (the cause of `writeWithoutResponse` drops under a burst). If you see
dropped fragments on your device, tune the timeout in `performWrite`.

## Source map

| File | Responsibility |
|------|----------------|
| `Crc16.kt` | CRC-16/CCITT-FALSE (table-driven). |
| `Protocol.kt` | Varint, `buildPacket`, `framePb`, 7 auth packets, teleprompter builders, `formatText`, heartbeat. |
| `EvenHub.kt` | proto3 wire helpers, prelude, Cmd constants, container builders, 4-bpp BMP, `Bitmap`→576×288 grayscale→2×2 tiles, response/event parsers. |
| `G2Connection.kt` | Dual-arm BLE (scan/connect/auth/heartbeat), serialized write queue, teleprompter flow, image streaming state machine. Exposes `state: StateFlow<G2State>`. |
| `BridgeService.kt` | Foreground service owning the connection + HTTP server. |
| `HttpServer.kt` | NanoHTTPD server (`/text`, `/image`, `/status`, `/`). |
| `MainActivity.kt` | Compose UI: permissions, Connect/Disconnect, status, server URL, test text. |

## Public API (`G2Connection`)

```kotlin
val state: StateFlow<G2State>                       // DISCONNECTED→…→READY
fun connect(); fun disconnect()
suspend fun displayText(text: String)               // teleprompter, both arms
suspend fun displayImage(bitmap: Bitmap)            // full-lens 2×2 image grid
suspend fun displayList(name: String, rows: List<String>)   // native list container
suspend fun showText(name: String, content: String)         // native text container
suspend fun updateText(name: String, content: String)       // cheap in-place text update
// Optional event callbacks: onListTap / onTextTap / onPageEvent / onDoubleTap
```

## Caveats

- **Uncompiled** - see the warning box at the top.
- The mic (LC3) path from the protocol §11 is **not implemented** (v1 skips it;
  the mic notify char is mapped and ignored).
- No auth on the HTTP server - use only on a trusted LAN.
- BMP/image: input is scaled-to-fit (letterboxed) into 576×288 and converted to
  4-bit grayscale via Rec. 601 luma.

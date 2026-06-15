# OpenEvenSdk

Drive Even Realities G2 glasses yourself - no Even app, no cloud. OpenEvenSdk is a
local-first toolkit for putting your own content on the G2 lens over Bluetooth,
straight from a device you control.

## What's here

| Folder | What it is |
|--------|-----------|
| [`claude-glass-bridge/`](claude-glass-bridge/) | **Python (Mac/PC).** Mirrors your live **Claude Code** sessions onto the glasses: it reads Claude Code's own transcripts and serves them over a small HTTP API. `bridge.py` = read-only mirror (Python stdlib only); `bridge_sdk.py` = read/write, which owns SDK-managed sessions so you can spawn / dictate / approve from the glasses. Tested on real hardware. |
| [`ios/`](ios/) | A SwiftUI iPhone app that connects both G2 arms over BLE and renders on the lens (and runs a small local HTTP server for pushing text/images directly). |
| [`android/`](android/) | A Kotlin/Compose port of the glasses app. Not yet device-tested. |
| [`PROTOCOL.md`](PROTOCOL.md) | The G2 BLE wire protocol - the byte-accurate source of truth the apps implement. |

## Run the bridge

```bash
# read-only mirror of your Claude Code sessions (no dependencies):
python3 claude-glass-bridge/bridge.py

# or read/write (spawn / dictate / approve from the glasses):
pip install -r claude-glass-bridge/requirements.txt
CLAUDE_GLASS_CWD=/path/to/repo python3 claude-glass-bridge/bridge_sdk.py
```

It prints a URL + token; put both into the app's Settings screen. The phone and the
computer running the bridge must be on the same Wi-Fi.

## The glasses app

See [`ios/README.md`](ios/README.md) and [`android/README.md`](android/README.md)
for building and pairing. The app owns the BLE link to both arms and speaks the
protocol in [`PROTOCOL.md`](PROTOCOL.md).

## How the G2 protocol works (90 seconds)

- The G2 is **two BLE peripherals** (one per arm). Text goes to *both*; the EvenHub
  container/image channel goes to the *right* arm only.
- Connect, send a fixed **7-packet auth handshake**, then a **~1.5 s heartbeat**
  keeps the link alive.
- **Text**: a paged "teleprompter" flow (25 cols x 10 lines).
- **Images / rich UI**: the **EvenHub** protocol - declare containers, then stream a
  4-bpp grayscale BMP tiled into a 2x2 grid across the 576x288 lens.
- Everything is CRC16/CCITT-framed in a simple `0xAA 0x21 ...` envelope.

Full byte layout, field numbers, and timing are in [`PROTOCOL.md`](PROTOCOL.md).

## Status

- **claude-glass-bridge** - working, tested on real G2 glasses. (`bridge.py` is
  stdlib-only; `bridge_sdk.py` needs `claude-agent-sdk` and the `claude` CLI on PATH.)
- **iOS** - tested on real G2 glasses.
- **Android** - ported from the protocol spec, not yet compiled or device-tested.

## Credits

The G2 BLE protocol is reverse-engineered from community work - see the Credits
section in [`PROTOCOL.md`](PROTOCOL.md) and the per-file headers.

## License

MIT. Use it, fork it, build on it.

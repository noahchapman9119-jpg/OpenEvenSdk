# Even Realities G2 - BLE protocol reference

This is the **single source of truth** for the wire protocol used by every client
in this repo (iOS, Android, Python). It is distilled from a verified-working
implementation that drives real G2 glasses **without the Even app**. Implement
exactly what is written here; the firmware silently drops anything malformed.

Everything below is little-endian unless stated otherwise.

---

## 1. Topology - the glasses are TWO peripherals

The G2 is **two independent BLE peripherals**, one per arm (left + right). Each
advertises a name containing `Even` (e.g. `Even G2_L_...` / `..._R_...`). You must
connect to **both**.

- **Text / teleprompter** must be written to **BOTH arms** (left first, then
  right, ~18 ms then ~12 ms pacing) or it does not render.
- **EvenHub** traffic (native containers, images, mic) goes to the **RIGHT ARM
  ONLY**. Sending EvenHub on the left arm wedges the firmware's plugin task.

Classify arms by advertised name: contains `_L_` or `LEFT` → left; `_R_` or
`RIGHT` → right; otherwise fill whichever slot is empty.

> iOS note: an arm already paired in OS Bluetooth settings is **not** returned by
> a scan - adopt already-connected peripherals first (`retrieveConnectedPeripherals`),
> then scan only for the missing arm.

## 2. GATT

| Role | UUID | Properties |
|------|------|-----------|
| Service (filter) | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | - |
| Control / teleprompter **write** | `00002760-08C2-11E1-9073-0E8AC72E5401` | writeWithoutResponse |
| Control **notify** (acks + events) | `00002760-08C2-11E1-9073-0E8AC72E5402` | notify |
| Binary / image **write** (optional) | `00002760-08C2-11E1-9073-0E8AC72E6401` | writeWithoutResponse |
| Mic LC3 **notify** | `00002760-08C2-11E1-9073-0E8AC72E6402` | notify |

In practice: discover **all** services/characteristics, subscribe to every
notify/indicate char, and pick the write target by UUID suffix (`2E5401`),
falling back to the first writable char. All real traffic uses the `…5401` write
char (writeWithoutResponse) and `…5402` notify.

## 3. CRC-16/CCITT-FALSE

Polynomial `0x1021`, init `0xFFFF`, **no** final XOR, MSB-first.

```
crc = 0xFFFF
for b in data:
    crc = ((crc << 8) ^ TABLE[((crc >> 8) ^ b) & 0xFF]) & 0xFFFF
# TABLE[i]: crc=i<<8; repeat 8x: crc = (crc & 0x8000) ? (crc<<1)^0x1021 : crc<<1
```

Appended **little-endian**: `[crc & 0xFF, (crc >> 8) & 0xFF]`.

## 4. Framing

### 4a. Single packet (`buildPacket`)

```
[0xAA][0x21][seq][len][0x01][0x01][svcHi][svcLo][payload...][crcLo][crcHi]
```
- `seq`  - 1-byte sequence, your choice (monotonic per logical flow).
- `len`  - `(payload.length + 2) & 0xFF`  (payload + 2 CRC bytes).
- `0x01 0x01` - fixed (single-fragment marker).
- `svcHi svcLo` - the service id pair for the command (see below).
- CRC16 is over **payload only**, appended LE.

### 4b. Multi-fragment envelope (`framePb`) - for payloads bigger than one chunk

Used for EvenHub messages (images especially). One CRC16 over the **whole**
payload, appended LE to the **last** fragment's data. All fragments share `seq`
(the firmware's reassembly key).

```
totalFrags = ceil((payload.length + 2) / chunk)        # +2 for the trailing CRC
for i in 0..totalFrags-1:
    isLast    = (i == totalFrags-1)
    chunkData = isLast ? payload[off:] + crcLE : payload[off:off+chunk]
    frame = [0xAA, 0x21, seq, chunkData.length & 0xFF, totalFrags, i+1, sid, flag] + chunkData
```
- `sid`  - service id (EvenHub = `0xE0`).
- `flag` - EvenHub request = `0x20`.
- `chunk` - `min(232, negotiatedMTU - 8)`; 8 = envelope header. Frames larger
  than MTU are silently dropped → reassembly abort.

## 5. Connect → authenticate → ready

1. Connect both arms, discover GATT, subscribe to notifies.
2. Send the **7 auth packets** to BOTH arms, ~100 ms apart, then wait ~500 ms.
   Auth packets embed a varint UNIX timestamp (seconds). Exact bytes
   (`ts = varint(unixSeconds)`, `txid = E8 FF FF FF FF FF FF FF FF 01`):

   | seq | svcHi svcLo | payload |
   |----|----|----|
   | 01 | 80 00 | `08 04 10 0C 1A 04 08 01 10 04` |
   | 02 | 80 20 | `08 05 10 0E 22 02 08 02` |
   | 03 | 80 20 | `08 80 01 10 0F 82 08 11 08` + ts + `10` + txid |
   | 04 | 80 00 | `08 04 10 10 1A 04 08 01 10 04` |
   | 05 | 80 00 | `08 04 10 11 1A 04 08 01 10 04` |
   | 06 | 80 20 | `08 05 10 12 22 02 08 01` |
   | 07 | 80 20 | `08 80 01 10 13 82 08 11 08` + ts + `10` + txid |

3. Start the heartbeat (§7). Status = ready.

## 6. Varint

Standard protobuf base-128 varint (LSB group first, high bit = continuation):
```
while v > 0x7F: out += (v & 0x7F) | 0x80; v >>= 7
out += v & 0x7F
```

## 7. Heartbeat (keep-alive)

The glasses' BLE supervision timeout is ~2000 ms - send a heartbeat every
**~1.5 s** or the link goes idle.

- **Teleprompter / text mode**: `buildPacket(seq, 0x80, 0x00, [0x08, 0x25])` to
  **both** arms.
- **EvenHub native/image mode**: EvenHub `Cmd=12` heartbeat (§9) on the **right
  arm only**, and **never before the first CREATE** (the plugin task doesn't exist
  yet).

## 8. Text display - teleprompter flow (svc `06 20`, config `0E 20`)

`formatText`: wrap to **25 chars/line**, **10 lines/page**, pad to **≥14 pages**.
Each page string is the 10 lines joined by `\n`, with a trailing `" \n"`.

Send order (single packets, both arms, with the noted pacing):
1. `displayConfig(seq, msgId)` - svc `0E 20`. (msgId starts at 0x14.)  → wait 150 ms
2. `teleprompterInit(seq, msgId, totalLines)` - svc `06 20`.            → wait 300 ms
3. `contentPage` for pages 0-9 - svc `06 20`.                          → 45 ms each
4. `marker(seq, msgId)` - svc `06 20`.                                 → 45 ms
5. `contentPage` for pages 10-11.                                      → 100 ms each
6. `sync(seq, msgId)` - svc `80 00` (activates rendering).             → 45 ms
7. `contentPage` for pages 12+.                                        → 100 ms each

Payload builders (payload passed to `buildPacket`; `vi()` = varint):

```
displayConfig(msgId):        svc 0E 20
  payload = [08 02 10] + vi(msgId) + [22 6A] + CONFIG_BLOB
  CONFIG_BLOB (hex) =
   08011213080210904E1D00E0944425000000002800300012130803100D0F1D00408D44
   2500000000280030001212080410001D000088422500000000280030001212080510001D
   00009242250000A242280030001212080610001D0000C642250000C44228003000 1800

teleprompterInit(msgId, totalLines, manual=true):   svc 06 20
  mode = manual ? 0x00 : 0x01
  contentHeight = max(1, totalLines * 2665 / 140)
  display = [08 01 10 00 18 00 20 8B 02]            # script idx, w=267
          + [28] + vi(contentHeight)
          + [30 E6 01]                              # line height 230
          + [38 8E 0A]                              # viewport 1294
          + [40 05 48 mode]                         # font 5 + scroll mode
  settings = [08 01 12 len(display)] + display
  payload  = [08 01 10] + vi(msgId) + [1A len(settings)] + settings

contentPage(msgId, pageNum, text):   svc 06 20
  textBytes = utf8("\n" + text)
  inner   = [08] + vi(pageNum) + [10 0A] + [1A] + vi(len(textBytes)) + textBytes
  content = [2A] + vi(len(inner)) + inner
  payload = [08 03 10] + vi(msgId) + content

marker(msgId):   svc 06 20
  payload = [08 FF 01 10] + vi(msgId) + [6A 04 08 00 10 06]

sync(msgId):     svc 80 00
  payload = [08 0E 10] + vi(msgId) + [6A 00]
```

The teleprompter VIEW self-times-out (~18 s); re-send the whole flow every ~11 s
to keep it on screen (BLE stays up via the heartbeat regardless).

## 9. EvenHub - native containers, images, mic (sid `0xE0`, flag `0x20`)

EvenHub messages are an inner **protobuf wrapper** sent via `framePb` (§4b) with
`sid=0xE0`, `flag=0x20`, on the **right arm only**.

Wrapper fields: `field 1 = Cmd` (varint), `field 2 = magic` (varint, your
correlation id, 1..120 rolling), plus one nested message field per command:

| Cmd | value | nested wrapper field |
|----|----|----|
| create     | 0  | `3` CreateStartUpPageContainer |
| event (RX) | 2  | `13` SendDeviceEvent |
| updateImage| 3  | `5`  ImageRawData |
| updateText | 5  | `9`  TextContainerUpgrade |
| rebuild    | 7  | `7`  RebuildPageContainer |
| shutdown   | 9  | `11` ShutDownCmd |
| privateEvent (RX) | 11 | `16` DevPrivateEvent |
| heartbeat  | 12 | `14` HeartBeatPacket |
| audioCtrl  | 15 | `18` AudioCtrCmd |
| audioRes (RX) | 16 | `19` AudioResCmd |

proto3 wire helpers (omit zero/empty scalars like protobuf-es):
`uintF(f,v)=tag(f,0)+vi(v)` (skip if 0); `strF(f,s)=tag(f,2)+vi(len)+bytes`
(skip if empty); `bytesF` same; `msgF(f,m)=tag(f,2)+vi(len)+m` (always emitted);
`tag(f,wire)=vi((f<<3)|wire)`.

### 9a. Container property field numbers (verified)

```
ImageObject:          X=1 Y=2 W=3 H=4 ContainerID=5 ContainerName=6
TextContainerProperty:X=1 Y=2 W=3 H=4 borderW=5 borderColor=6 borderRadius=7
                      padding=8 ContainerID=9 ContainerName=10 IsEventCapture=11 Content=12
ListContainerProperty:X=1 Y=2 W=3 H=4 borderW=5 borderColor=6 borderRadius=7
                      padding=8 ContainerID=9 ContainerName=10 ItemContainer=11 IsEventCapture=12
List_ItemContainerProperty: ItemCount=1 ItemWidth=2 IsItemSelectBorderEn=3 ItemName(repeated)=4
CreateStartUpPageContainer: ContainerTotalNum=1 ListObject=2 TextObject=3 ImageObject=4 widgetId=5
RebuildPageContainer:       ContainerTotalNum=1 ListObject=2 TextObject=3 ImageObject=4
TextContainerUpgrade:       ContainerID=1 ContainerName=2 ContentOffset=3 ContentLength=4 Content=5
ImageRawData: ContainerID=1 Name=2 SessionId=3 TotalSize=4 (CompressMode=5,omit) FragmentIndex=6 DataLen=7 Data=8
```

**Container names must be ≤ 14 bytes** or the firmware rejects them. Never send a
zero-length list item or text content - proto3 drops it and counts mismatch
(substitute `"·"`).

### 9b. App-launch prelude (sid `0x01`) - once per BLE session, right arm

Send verbatim before the first CREATE:
```
AA 21 92 13 01 01 01 20 08 02 10 9C 01 22 0A 1A 08 12 06 12 04 08 00 10 00 A1 42
```

### 9c. Result codes (notify, sid `0xE0`)

Even = success, odd = failure: createOK=0, createInvalid=1, imageOK=4,
imageFAILED=5, rebuildOK=6, rebuildFAILED=7, textOK=8, textFailed=9, heartbeatOK=12.
**createOK=0 is omitted on the wire** (parses as "no result") - treat a missing
result on a create ack as success.

### 9d. Native text/list page (fast, tappable - preferred for text UIs)

1. prelude → `Cmd=0 create` ONE full-lens list container (576×288, id=1,
   name `"hud"`, items `["…"]`, widgetId=10000, magic=201). Create **once** per
   session; do NOT shutdown+recreate on navigation (kills tap focus).
2. To show a list:  `Cmd=7 rebuild` with one ListObject (same name).
3. To show text:    `Cmd=7 rebuild` with one TextObject (switches the shape).
4. Cheap text update on a live text container: `Cmd=5 updateText`
   (ContentOffset=0, full snapshot ≤ ~1000 bytes) - flicker-free.

### 9e. Images - 4-bpp BMP, 2×2 tile grid

The lens is **576×288**. Firmware max per image is ~20 KB, so tile a full frame
into a **2×2 grid of 288×144** tiles (ids 10/11/12/13, names `t0..t3`,
positions TL/TR/BL/BR).

**BMP format** (`bmp4`): standard Windows BMP, **4 bits/pixel**, bottom-up rows,
4-byte row stride, 16-entry grayscale palette (`entry i = (i*17, i*17, i*17)`).
`pixel(x,y)` returns 0..15 (0=off, 15=bright). Header: `BM`, 40-byte BITMAPINFOHEADER,
pixelOffset = 14+40+64, biBitCount=4, biClrUsed=16.

**Streaming** (per tile):
1. prelude → `Cmd=0 create` the 4 image containers (the grid) once. magic=201.
2. For each tile: pick a new `SessionId` (monotonic, +2 to escape a wedge),
   split the BMP into **≤3800-byte data fragments**, send each as
   `Cmd=3 updateImage` (FragmentIndex 0-based), with a **sliding window of 4
   in-flight acks**. Wait for `imageOK=4`. >3 consecutive missed acks ⇒ wedged.
3. The firmware silently drops the **first** Cmd=3 burst after a CREATE - send a
   sacrificial "warmup" stream first.
4. Send an inline `Cmd=12 heartbeat` between tiles so the ~10 s plugin watchdog
   never fires mid-burst.

### 9f. Flow control

`writeWithoutResponse` is **silently dropped** when the radio's TX queue is full
(this is the cause of reassembly aborts under a burst). Before each write, wait
until the stack reports it can send (iOS `canSendWriteWithoutResponse` /
`peripheralIsReady`; Android: throttle / wait for `onCharacteristicWrite` pacing).

## 10. Incoming events (notify, sid `0xE0`)

A notify whose byte[0]=`0xAA` and byte[6]=`0xE0` is an EvenHub frame; payload =
bytes[8:]. byte[7]=flag: `0x20` request ack; `0x01`/`0x06` async event.

- Ack: parse wrapper → `{cmd, magic, result}`; resolve the pending magic.
- Event (`Cmd=2`, DevEvent field 13): `List_ItemEvent{ContainerID=1,
  ContainerName=2, SelItemName=3, SelItemIndex=4, EventType=5}`,
  `Text_ItemEvent{ContainerID=1, ContainerName=2, EventType=3}`,
  `Sys_ItemEvent{EventType=1,…}`.
- EventType: CLICK=0, SCROLL_TOP=1, SCROLL_BOTTOM=2, DOUBLE_CLICK=3,
  FOREGROUND_ENTER=4, FOREGROUND_EXIT=5, ABNORMAL_EXIT=6, SYSTEM_EXIT=7.
- The firmware **double-delivers** a single physical tap (2-3 identical CLICKs) -
  debounce ~350 ms. Double-tap arrives as a SYS event type 3.
- On FOREGROUND_EXIT/ABNORMAL_EXIT/SYSTEM_EXIT the page is gone - re-prime
  (re-create) before the next paint.

## 11. Mic (optional, LC3) - Cmd=15 / RX Cmd=16

A StartUpPage must exist first. Send `Cmd=15 audioCtrl` with `AudioCtrCmd{AudoFuncEn=1}`
(field 18) to start, `=0` to stop, on right arm (mirror to left too - the stream
may come from either). The firmware may not reliably ack - arm optimistically.
While active, each `…2E6402` notify is a raw ~205-byte LC3 frame (decode to
16 kHz mono Int16 PCM). v1 of this bridge can skip the mic.

## 12. Geometry quick reference

- Lens: **576 × 288** px. Image tiles: **288 × 144** (2×2 grid).
- Teleprompter text: 25 chars/line, 10 lines/page.
- Native text/list container: full-lens 576×288, single container id=1.

---

## Credits

Even Realities publishes no official protocol spec - everything here is
reverse-engineered from community work, then re-verified against real G2 hardware.
This document and OpenEvenSdk build directly on:

- **[i-soxi/even-g2-protocol](https://github.com/i-soxi/even-g2-protocol)** - the
  teleprompter text flow, the `0xAA 0x21` framing, the CRC16/CCITT framing, and the
  auth-packet sequence (§3-§8) follow its verified-working teleprompter reference.
- **[Commute773/g2-kit-unofficial](https://github.com/Commute773/g2-kit-unofficial)**
  (“g2-kit”) - the EvenHub container/image protocol (§9): the protobuf wrapper, the
  container/field numbers (reconstructed from the decompiled Even app), the 4-bpp
  BMP tiling, and the image-streamer design (sliding ack window, session-id jump,
  warmup burst).
- **Even Realities** - the G2 hardware and BLE firmware this all speaks to.

Corrections, field-number fixes, and hardware test reports are very welcome - open
an issue or PR.

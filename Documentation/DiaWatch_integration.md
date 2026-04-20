# DiaWatch BLE Integration

Sends CGM glucose readings from Loop to a [DiaWatch](https://github.com/joaquimorg/DiaWatch) PineTime watch over Bluetooth Low Energy, using the Nordic UART Service (NUS) protocol.

## How it works

Every time the G7 (or any connected CGM) delivers a new reading, Loop pushes it to the paired watch in the format the DiaWatch firmware expects:

```
GB({"face":"diawatch","t":"reading","v":120,"trend":" -","ts":1712345678})\r\n
```

The message is split into 20-byte chunks and written to the NUS RX characteristic. Loop stays connected for ~2 seconds after the last chunk so the watch can drain its UART buffer, then disconnects cleanly.

This works in the background — no need to keep the app open.

## Pairing

1. Open Loop → **Settings** → scroll to the **DiaWatch** row
2. Tap it, then tap **Scan for device**
3. Make sure the watch is nearby and not connected to anything else
4. All nearby BLE devices appear in the list with their name and signal strength — pick your PineTime / DiaWatch
5. Tap **Pair**

After pairing, Loop reconnects automatically on every new glucose reading. No need to re-pair unless you tap **Forget device** or reinstall the app.

> **Note on "pairing":** This is not classic Bluetooth pairing (no PIN, no system dialog). Loop simply stores the watch's CoreBluetooth UUID so it can reconnect instantly without scanning. NUS on wasp-os does not require bonding or encrypted access.

## Settings screen

| Element | What it does |
|---|---|
| Paired device name | Shows the currently paired watch, or "Not paired" |
| **Forget device** | Unpairs and stops all pushes |
| **Scan for device** | Starts a 10-second scan of all nearby BLE devices |
| Signal strength (dBm) | Shown next to each device in the scan list; green > −60, yellow −60 to −80, red below −80 |
| Last push | Relative time of the most recent successful push |
| Error | Last connection or send error, if any |
| **Send test reading (190 mg/dL)** | Immediately pushes a hardcoded reading of 190 mg/dL with flat trend — useful for confirming the watch is receiving correctly without waiting for the next CGM reading |

## Preset defaults

New presets are created with these defaults:

| # | Field | Default | UI label | Wire key |
|---|---|---|---|---|
| 1 | `name` | `"default"` | Name | `n` |
| 2 | `wakeOnReading` | `false` | Display wakes on new readings | `rw` |
| 3 | `displayBrightness` | `2` (Mid) | Display brightness | `db` |
| 4 | `displayAlwaysOn` | `false` | Display always on | `ds` (null when true) |
| 5 | `displaySleepSec` | `10` | Display sleep: 10 sec | `ds` (integer) |
| 6 | `forecaster` | `.trend` | Forecaster: Trend | `fc` ("Trend") |
| 7 | `od` | `10` min | Outdated data | `od` |
| 8 | `nd` | `30` min | No data | `nd` |
| 9 | `st` | `.nothing` (0) | Single tap | `st` |
| 10 | `dt` | `.wake` (1) | Double tap | `dt` |
| 11 | `lt` | `.nothing` (0) | Long tap | `lt` |
| 12 | `sp` | `.wake` (1) | Short button press | `sp` |
| 13 | `lp` | `.haptics` (2) | Long button press | `lp` |
| 14 | `rangeCutoffs` | `[70, 100, 200, 300]` | Cutoff steppers | `rc` |
| 15 | `rangeHaptics` | `["single_buzz", "notification", "notification_single", "stutter", "stutter_long"]` | Haptic per range | `rh` |
| 16 | `rangePlayHaptic` | `[true, true, false, false, false]` | Play on new readings | `ph` |
| 17 | `hapticAlerts` | Slot 1: disabled, `< 90`, `single_buzz`; slots 2–5: disabled, `> 180`, `single_buzz` | Alert 1–5 | `s_a` / `d_a` |

## Trend arrows

Loop's 7-level trend scale is mapped to the 5 two-character symbols DiaWatch supports:

| Loop trend | DiaWatch |
|---|---|
| Rising very fast | `>>` |
| Rising fast | `>>` |
| Rising | `> ` |
| Flat | ` -` |
| Falling | `< ` |
| Falling fast | `<<` |
| Falling very fast | `<<` |

## Technical details

### BLE UUIDs
- **NUS service:** `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- **RX characteristic** (phone writes to this): `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- **TX characteristic** (watch sends on this): `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

### Connection sequence
Every push follows this exact sequence:

```
1. retrievePeripherals(withIdentifiers: [storedUUID])
   → if found: connect directly (no scan needed)
   → if not found: scanForPeripherals(withServices: [NUS UUID]) as fallback

2. centralManager(_:didConnect:)
   → discoverServices([NUS service UUID])

3. peripheral(_:didDiscoverServices:)
   → discoverCharacteristics([RX UUID, TX UUID])

4. peripheral(_:didDiscoverCharacteristicsFor:)
   → setNotifyValue(true, for: txCharacteristic)   ← REQUIRED by wasp-os

5. peripheral(_:didUpdateNotificationStateFor:)
   → begin writing 20-byte chunks to RX characteristic
   → uses .withoutResponse; honours canSendWriteWithoutResponse flow control
   → peripheralIsReady(toSendWriteWithoutResponse:) resumes if flow-controlled

6. all chunks sent
   → wait 2 seconds (watch drains its UART buffer)
   → cancelPeripheralConnection

7. centralManager(_:didDisconnectPeripheral:)
   → record lastPushDate, clear error
```

### Why TX subscription is mandatory
wasp-os NUS firmware only activates its RX data handler once a central has subscribed to TX notifications (written `0x0100` to the TX CCCD). Without this step, the watch physically receives the BLE writes but silently ignores them — the data never reaches the MicroPython application layer. This is a common pattern in embedded NUS firmware and is easy to miss because CoreBluetooth reports no error and the push appears to complete successfully from the phone's perspective.

### Write flow control
NUS RX uses write-with-response (ATT acknowledged writes). Each chunk's link-layer ACK gates the next write via the `peripheral(_:didWriteValueFor:error:)` delegate callback, pacing writes to whatever rate the watch's BLE controller can sustain. This protects the wasp-os RX buffer from overruns that could silently drop bytes and produce malformed JSON on the watch side.

### Send timeout
A 15-second watchdog timer starts when each push begins. If anything stalls — connection attempt, service discovery, TX subscription, or writing — the timer fires, cancels the peripheral connection, and resets all state so the next glucose reading can attempt a fresh push. The timeout is cancelled immediately on all normal terminal paths (clean disconnect, connection failure, TX subscription callback).

### Reconnection strategy
- Normal operation (after first pairing): `retrievePeripherals(withIdentifiers:)` returns the watch instantly from CoreBluetooth's cache. No scan occurs.
- After a full app reinstall: the CoreBluetooth cache is cleared, so the UUID is no longer known to the OS. The fallback scan fires, discovers the watch by NUS service UUID, and reconnects. The stored UUID is NOT automatically updated in this path — re-pair manually via Settings if this happens repeatedly.

### Persistence
- Paired peripheral UUID: `UserDefaults` key `com.loopkit.Loop.DiaWatch.peripheralID`
- Paired device name: `UserDefaults` key `com.loopkit.Loop.DiaWatch.deviceName`

### Source files
- `Loop/Managers/DiaWatchManager.swift` — all BLE logic, push trigger, pairing, timeout
- `Loop/Views/DiaWatchSettingsView.swift` — SwiftUI settings screen
- `Loop/Extensions/UserDefaults+Loop.swift` — persistence keys

## Transmission status lifecycle

The DiaWatch settings screen shows a permanent "Status" row that reflects the current state of the BLE pipeline. On fresh app launch with no prior transmissions it shows "Idle" (gray). After a transmission completes, the status always ends with ", idle" prefixed by the outcome.

### Phases

| Phase | Label | Spinner |
|---|---|---|
| `.idle` (no error, no prior transmission) | Idle | no |
| `.idle` (no error, after transmission) | OK, idle | no |
| `.idle` (with error) | *error text*, idle | no |
| `.connecting` | Connecting... | yes |
| `.sending` | Sending... | yes |
| `.awaitingResponse` | Awaiting response... | yes |
| `.purging` | Purging... | yes |
| `.retrying(attempt, of)` | MemoryError, retrying (N/3)... | yes |

### Scenario a) Correct transmission

| Transmission status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged) |
| Sending... | ~0.5s | (unchanged) |
| Awaiting response... | ~1-2s | updates with watch output |
| OK, idle | final | timestamp updates to now |

### Scenario b) Connection OK, wrong response (watch returns ERROR)

| Transmission status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged) |
| Sending... | ~0.5s | (unchanged) |
| Awaiting response... | ~1-2s | updates with watch ERROR output |
| Watch rejected ..., idle | final (orange) | timestamp updates to now |

### Scenario c) Connection OK, no response (watch is unresponsive)

| Transmission status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged, stale) |
| Sending... | ~0.5s | (unchanged, stale) |
| Awaiting response... | 20s | no update |
| Purging... | 30s | (unchanged) |
| Connecting... | ~1-3s | (unchanged) |
| Sending... | ~0.5s | (unchanged) |
| Awaiting response... | 20s | still silent |
| No echo from watch, idle | final (orange) | stale timestamp |

Total wall time: ~75 seconds (first attempt + purge wait + retry).

### Scenario d) Cannot connect (watch off or out of range)

| Transmission status | Duration | Last response |
|---|---|---|
| Connecting... | up to 15s | (unchanged, stale) |
| Send timed out, idle | final (orange) | stale timestamp |

If BLE outright rejects the connection (wrong peripheral UUID), `didFailToConnect` fires immediately:

| Transmission status | Duration | Last response |
|---|---|---|
| Connecting... | instant | (unchanged) |
| Connection failed, idle | final (orange) | stale timestamp |

### Last transmission response

The "Last transmission response" area in the Debug section shows the raw text received from the watch on the NUS TX characteristic during the most recent session. It includes the REPL echo, the watch's log output, and any error messages. A timestamp (e.g., "@ 14:23 16/4/2026") indicates when the last response byte arrived. If the timestamp is stale, the watch has not responded since that time.

### Error handling and result evaluation

All transmission completions go through `evaluateResult(rejectMessage:)` which checks, in order:

1. No response received at all → "No response from watch"
2. Echo detected but no `>>>` prompt (REPL never returned) → "Watch did not complete execution"
3. Response contains "error" (case-insensitive) → per-command reject message
4. Otherwise → OK (nil error)

Glucose readings additionally verify that "reading received" appears in the response even if no error was found.

| # | Scenario | Handled | What happens |
|---|---|---|---|
| 1 | Watch echoes command but crashes before processing (no `>>>`) | Yes | `evaluateResult` detects `echoDetected && replPromptCount == 0` → "Watch did not complete execution, idle" |
| 2 | Watch sends partial response then disconnects | Partially | If disconnect happens mid-send → "Disconnected mid-send, idle". If after chunks written but before `>>>` → caught by scenario 1. If `>>>` arrived but response is incomplete → currently marked OK (no check on response completeness) |
| 3 | Watch responds with a Python traceback (no "ERROR" string) | Yes | `evaluateResult` uses case-insensitive check for "error" — Python tracebacks end with `...Error:` (e.g., `TypeError:`, `ValueError:`, `KeyError:`) so they are caught |
| 4 | Watch responds with MemoryError | Yes | Retries up to 3 times at 10-second intervals (no preamble). Shows "MemoryError, retrying (1/3)...". After 3 failures → per-command reject message + ", idle" |
| 5 | No response at all within 20s | Yes | Response timer fires → disconnect → purge + retry with preamble → if still no echo → "No echo from watch, idle" |
| 6 | Cannot connect at all | Yes | 15s send timeout → "Send timed out, idle". Or immediate CoreBluetooth delegate callback `didFailToConnect` → "Connection failed, idle" |
| 7 | Correct transmission, watch confirms | Yes | "OK, idle" (green) |
| 8 | Watch responds with "ERROR" (any case) | Yes | `evaluateResult` catches case-insensitive "error" → per-command reject message + ", idle" (orange) |

## Troubleshooting

### Watch isn't appearing during scan
The scan shows **all** nearby BLE devices (no name or service filter), so the watch will appear under whatever name the firmware advertises (typically `"PineTime"`). If nothing appears:
- Confirm the watch is not already connected to another phone or app — a PineTime can only maintain one active BLE connection at a time
- Keep the watch within ~1 metre during the scan
- The scan runs for 10 seconds and then stops automatically — tap **Scan for device** again to retry
- If the watch is brand new or freshly flashed, give it a few seconds after boot before scanning

### Readings are not appearing on the watch after pairing
This means the BLE writes are completing but the watch firmware is not reacting. Most likely causes:

1. **TX subscription was not sent** — if you are running a very old build of this integration (before the TX subscription fix), the watch will receive the data but ignore it. Update to the latest build.
2. **Watch face is not set to DiaWatch** — the `"face": "diawatch"` field in the message must match the active face on the watch. If the watch is displaying a different face, it will not respond to the message.
3. **Watch is connected to another device** — if the watch accepted our connection but is also trying to maintain a connection to another central, behaviour can be unpredictable.

### "Last push" stopped updating / error shown
- Check that Loop is still receiving CGM readings (main Loop status screen — if glucose is stale there, the problem is upstream of DiaWatch)
- Check the error text in the DiaWatch settings row for the specific failure message
- A "Send timed out" error means the watch accepted the BLE connection but stopped responding mid-sequence — this can happen if the watch goes to sleep aggressively or the BLE signal dropped after connecting. The next reading will retry automatically.
- If errors persist, tap **Forget device** and re-pair

### Readings appear on the watch but are delayed
This is expected behaviour. The push happens when Loop finishes processing the CGM reading, which is a few seconds after the sensor transmits it. The delay is the same as what Loop shows on its own status screen.

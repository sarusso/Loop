# DiaWatch BLE Integration

Pushes CGM glucose readings from Loop to a PineTime watch running [DiaWatch](https://github.com/sarusso/DiaWatch) firmware over Bluetooth Low Energy, using the Nordic UART Service (NUS) protocol.

## How it works

Every time Loop's glucose store updates, Loop drains **every unsent sample** since the last successful push to the paired watch, in chronological order:

```
GB({"app":"dw","t":"r","v":156,"tr":"u","ts":1712345678})\r\n
```

Each message is split into 20-byte chunks and written to the NUS RX characteristic using write-with-response (ATT acknowledged writes). After all chunks are sent, Loop waits for the watch to echo the command, return `reading received`, and re-emit a `>>>` prompt, then disconnects. Only after the watch confirms receipt is the per-sample watermark advanced and persisted.

This works in the background — no need to keep the app open. See [Reading delivery](#reading-delivery) for the full guarantees.

## Reading delivery

Reading transmission uses a **watermark-and-drain** model:

- The persisted `lastSentTs` (UserDefaults `com.loopkit.Loop.DiaWatch.lastSentTs`) holds the Unix-seconds timestamp of the most recent reading the watch *confirmed* it received (i.e. responded with `reading received` and a clean `>>>`).
- Whenever LoopKit posts `LoopDataUpdated` with `.glucose` context, `DiaWatchManager.drainReadings()` queries `glucoseStore` for every sample with `startDate > max(lastSentTs, now − maxBackfillInterval)`, sorted ascending, and sends them one at a time over BLE.
- `lastSentTs` advances **only on confirmed success**. On any send failure, the drain stops; the next `LoopDataUpdated.glucose` notification re-queries from the un-advanced watermark and naturally retries.
- A re-entry guard (`isDrainingReadings`) prevents concurrent drains when notifications fire while one is already in progress.
- `DiaWatchManager.maxBackfillInterval` (default `2 * 60 * 60` = 2 hours) caps how far back the watermark can effectively reach — after long offline periods (sleep, app crash, prolonged BLE outage) the older samples beyond the cap are silently skipped to avoid flooding the watch with stale data.

### Why this design

The notification we hook into (`LoopDataUpdated.glucose`) is fired by LoopKit whenever `GlucoseStore.glucoseSamplesDidChange` fires — and that is fired by **six** code paths in `GlucoseStore`, not just "new CGM reading arrived" (also: HealthKit syncs, cache purges, manual entries, sample replacements, etc.). The previous "send `latestGlucose` on every notification" model produced duplicate timestamps (notification fires without `latestGlucose` changing) and silently dropped backfilled intermediate samples (only the newest of a batch was ever sent). The watermark+drain model uses the per-sample identity in the store as the source of truth instead of trusting the notification cadence.

### Behaviour matrix

| Scenario | Outcome |
|---|---|
| Fresh install, CGM running | First push arrives ~5 min after install; up to 2 h of cached samples are sent in chronological order. |
| Spurious `glucoseSamplesDidChange` (no new sample) | Query returns empty; no-op. No duplicate sent. |
| Backfill of 30 min (6 samples) after gap | All 6 sent in order; ~30–60 s of BLE traffic. |
| Backfill of 5 h (60 samples) after long offline | Only the last 2 h (24 samples) are sent; older 36 are permanent holes (intentional cap). |
| Send #3 of 6 fails | Drain stops; `lastSentTs` reflects sample #2's ts. Next CGM reading (~5 min later) re-queries, finds #3 still pending plus the new one, sends both. |
| App crash mid-drain | On relaunch, persisted `lastSentTs` reflects the last *confirmed* send. Next CGM reading drains the rest. |
| Concurrent notification while draining | Re-entry guard skips it. The currently-running drain picks up newer samples on its next iteration. |
| Out-of-order: `glucoseStore.latestGlucose` momentarily resolves to an older sample | Query still returns nothing greater than `lastSentTs`. No backwards send. |
| Test push (debug "Push test" button) | Bypasses drain and watermark; sends a synthetic reading at `Date()`. Watch silently dedups if `ts` is older than its own last received. Does **not** advance `lastSentTs`. |

## Pairing

1. Open Loop → **Settings** → scroll to the **DiaWatch** row
2. Tap it, then tap **Scan for device**
3. Make sure the watch is nearby and not connected to anything else
4. All nearby BLE devices appear in the list with their name and signal strength — pick your PineTime
5. Tap **Pair**

After pairing, Loop reconnects automatically on every new glucose reading. No need to re-pair unless you tap **Forget device** or reinstall the app.

> **Note on "pairing":** This is not classic Bluetooth pairing (no PIN, no system dialog). Loop simply stores the watch's CoreBluetooth UUID so it can reconnect instantly without scanning. NUS on wasp-os does not require bonding or encrypted access.

## Settings screen

The DiaWatch settings screen is divided into four sections:

### Status section

| Element | What it does |
|---|---|
| Paired device name + **Forget** | Shows the currently paired watch; Forget unpairs and stops all pushes |
| **Scan for device** | Starts a 10-second scan of all nearby BLE devices |
| **Set time** | Sends the phone's current wall-clock time and UTC offset to the watch via `s_t` |
| **Push readings** | Toggle — when ON, glucose readings are automatically pushed to the watch. Persists across app restarts |
| Last push | Shows the most recent pushed value and time (e.g., "156 mg/dL at 14:23:07") |
| No readings pushed yet | Shown when no push has occurred this session |
| Status | Permanent row showing the BLE pipeline state (see [Transmission status lifecycle](#transmission-status-lifecycle)) |

### Presets section

| Element | What it does |
|---|---|
| Preset picker | Dropdown to select the active preset |
| Duplicate (doc icon) | Creates a copy of the current preset with " copy" appended |
| New (+ icon) | Creates a new preset with defaults. Max 4 presets |
| **Activate** | Sends `a_p` to the watch to switch the active preset |
| **Delete** | Removes the last preset (only enabled when viewing the last preset and more than 1 exists) |
| **General / Ranges / Alerts** | Segmented tab picker for the three configuration tabs |
| **Save** | Saves the current tab's settings to the watch via BLE. Only persists to UserDefaults after BLE confirmation succeeds |

**General tab:** Name, Display brightness (Low/Mid/High), Display always on, Display sleep (hidden when always on), Display wakes on new readings (hidden when always on), Single/Double/Long tap actions, Short/Long button press actions, Forecaster, Outdated data, No data.

**Ranges tab:** 5 glucose ranges (Very Low / Low / OK / High / Very High) separated by 4 cutoff steppers. Each range has a haptic pattern picker and a "Play on new readings" toggle.

**Alerts tab:** 5 individually configurable haptic alerts, each with an enable toggle, above/below operator, mg/dL threshold, and haptic pattern.

### Test Haptics section

Pattern picker + **Play** button — sends a MicroPython command to play the selected haptic pattern on the watch immediately.

### Debug section (collapsed by default)

| Element | What it does |
|---|---|
| Test value stepper + **Send test reading** | Pushes a reading with the chosen mg/dL value and flat trend |
| **Get battery / Get free mem / Get free mem blocks / Get uptime** | Sends MicroPython one-liners to query watch state |
| **Send Ctrl-C** | Sends `\x03` to interrupt any running command on the watch |
| Custom command + **Send** | Free-form MicroPython command entry |
| **Start / Stop log stream** | Opens a listen-only BLE connection — no probe, no payload, just streams everything the watch sends into the response area |
| Last transmission response | Scrollable text area showing raw NUS TX data from the most recent session, with timestamp (e.g., "@ 14:23 16/4/2026") |

## Wire protocol

All messages use the `GB({...})\r\n` envelope. The `app` key is always `"dw"`.

### Reading push (`t: "r"`)

```json
{"app":"dw","t":"r","v":156,"tr":"u","ts":1712345678}
```

| Key | Type | Meaning |
|---|---|---|
| `v` | int | Glucose value in mg/dL |
| `tr` | string | Trend code (see [Trend codes](#trend-codes)) |
| `ts` | int | Unix timestamp (seconds since epoch) |

### Save general config (`t: "s_c"`)

```json
{"app":"dw","t":"s_c","p":0,"n":"default","rw":0,"db":2,"ds":10,"fc":"Trend","od":10,"nd":30,"st":0,"dt":1,"lt":0,"sp":1,"lp":2}
```

| Key | Type | Meaning |
|---|---|---|
| `p` | int | Preset index |
| `n` | string | Preset name |
| `rw` | 0/1 | Wake display on new readings |
| `db` | 1-3 | Display brightness (1=Low, 2=Mid, 3=High) |
| `ds` | int or null | Display sleep in seconds; null = always on |
| `fc` | string or null | Forecaster name ("Trend"); null = none |
| `od` | int | Outdated data threshold in minutes |
| `nd` | int | No data threshold in minutes |
| `st` | 0-2 | Single tap action (0=nothing, 1=wake/sleep, 2=haptics) |
| `dt` | 0-2 | Double tap action |
| `lt` | 0-2 | Long tap action |
| `sp` | 0-2 | Short button press action |
| `lp` | 0-2 | Long button press action |

### Save ranges (`t: "s_r"`)

```json
{"app":"dw","t":"s_r","p":0,"rc":[70,100,200,300],"rh":["single_buzz","notification","notification_single","stutter","stutter_long"],"ph":[1,1,0,0,0]}
```

| Key | Type | Meaning |
|---|---|---|
| `p` | int | Preset index |
| `rc` | [int; 4] | Glucose cutoffs in mg/dL, strictly ascending |
| `rh` | [string; 5] | Haptic pattern name per range (Very Low → Very High) |
| `ph` | [0/1; 5] | Play haptic on new reading for each range |

### Save alert (`t: "s_a"`) / Delete alert (`t: "d_a"`)

```json
{"app":"dw","t":"s_a","p":0,"idx":0,"op":"<","thr":90,"pat":"single_buzz"}
{"app":"dw","t":"d_a","p":0,"idx":0}
```

| Key | Type | Meaning |
|---|---|---|
| `p` | int | Preset index |
| `idx` | int | Alert slot index (0-4) |
| `op` | ">" or "<" | Comparison operator |
| `thr` | int | Glucose threshold in mg/dL |
| `pat` | string | Haptic pattern name |

Enabled alerts send `s_a`; disabled alerts send `d_a`. All 5 slots are sent on each save.

### Activate preset (`t: "a_p"`)

```json
{"app":"dw","t":"a_p","p":1}
```

### Delete preset (`t: "d_p"`)

```json
{"app":"dw","t":"d_p","p":1}
```

### Set time (`t: "s_t"`)

```json
{"app":"dw","t":"s_t","lt":[2026,4,16,14,23,7],"ff":7200}
```

| Key | Type | Meaning |
|---|---|---|
| `lt` | [int; 6] | Local time: [year, month, day, hour, minute, second] |
| `ff` | int | UTC offset in seconds east of UTC (DST-aware) |

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
| 17 | `hapticAlerts` | Slot 1: disabled, `< 90`, `single_buzz`; slots 2-5: disabled, `> 180`, `single_buzz` | Alert 1-5 | `s_a` / `d_a` |

## Trend codes

Loop's 7-level trend scale is mapped to compact string codes:

| Loop trend | Code | Meaning |
|---|---|---|
| Rising very fast | `uuu` | up-up-up |
| Rising fast | `uu` | up-up |
| Rising | `u` | up |
| Flat | `f` | flat |
| Falling | `d` | down |
| Falling fast | `dd` | down-down |
| Falling very fast | `ddd` | down-down-down |

## Available haptic patterns

```
simple_pulse, single_buzz, single_buzz_short, single_buzz_long,
triple_tap, heartbeat, urgent, linear_ramp, short_long, long_short,
double_tap, notification, notification_single, bounce, rbounce,
countdown, stutter, stutter_short, stutter_long, sos, fanfare,
uprising_sweep
```

## Technical details

### BLE UUIDs

- **NUS service:** `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- **RX characteristic** (phone writes to this): `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- **TX characteristic** (watch sends on this): `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

### Connection sequence

Every push follows this sequence:

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
   → probeForPrompt(): send \r to solicit >>> from the REPL
   → on preamble retry: send \x03\x03\r instead
   → arm 5-second prompt timeout

6. >>> detected in TX response
   → cancel prompt timeout, clear bleResponse
   → begin writing 20-byte chunks via .withResponse
   → peripheral(_:didWriteValueFor:) fires after each ATT ACK → next chunk

7. all chunks sent
   → cancel send timeout, set .awaitingResponse
   → arm response timer (20s initial wait for first byte)

8. watch responds on TX (echo + output + >>> prompt)
   → response timer resets on each byte (1.5s idle timeout)
   → >>> count accelerates disconnect (2 prompts → 0.2s, 1 → 0.5s)

9. response timer fires → cancelPeripheralConnection

10. centralManager(_:didDisconnectPeripheral:)
    → evaluateResult: check echo, >>>, errors
    → drain transmissionQueue if more commands pending
    → or enter purge cycle if no echo and purge enabled
```

If the REPL prompt does not arrive within 5 seconds in step 5 (e.g., watch is booting), the send is aborted with "REPL not ready" — no payload is written, preventing boot interruption.

### Why TX subscription is mandatory

wasp-os NUS firmware only activates its RX data handler once a central has subscribed to TX notifications (written `0x0100` to the TX CCCD). Without this step, the watch physically receives the BLE writes but silently ignores them — the data never reaches the MicroPython application layer.

### Write flow control

NUS RX uses write-with-response (ATT acknowledged writes). Each chunk's link-layer ACK gates the next write via the `peripheral(_:didWriteValueFor:error:)` delegate callback, pacing writes to whatever rate the watch's BLE controller can sustain. This protects the wasp-os RX buffer from overruns that could silently drop bytes and produce malformed JSON on the watch side.

### Send timeout

A 15-second watchdog timer starts when each push begins. If anything stalls — connection attempt, service discovery, TX subscription, prompt probe, or writing — the timer fires, cancels the peripheral connection, and resets all state so the next glucose reading can attempt a fresh push.

### REPL prompt probe

After connecting and subscribing to TX notifications, Loop sends a bare `\r` and waits up to 5 s for a prompt. The **last** prompt token received decides what happens next:

- `>>>` → REPL is at the top level, proceed to write the payload chunks
- `...` → REPL is in a multi-line continuation (stuck mid-input). Loop sends `\x03\x03\r` (Ctrl-C twice + CR) once to break out, then waits a fresh 5 s for `>>>`
- neither within 5 s → abort with "REPL not ready"

This eliminates the need for a separate purge/retry cycle: the recovery happens inline during the probe instead of after a failed transmission.

### Log stream

The Debug section offers a listen-only BLE connection mode. Start log stream connects and subscribes to TX notifications but skips the REPL prompt probe and sends no payload. All incoming data is displayed in the response area in real-time. Useful for watching watch-side log output. Stop disconnects cleanly.

### Reconnection strategy

- Normal operation (after first pairing): `retrievePeripherals(withIdentifiers:)` returns the watch instantly from CoreBluetooth's cache. No scan occurs.
- After a full app reinstall: the CoreBluetooth cache is cleared, so the UUID is no longer known to the OS. The fallback scan fires, discovers the watch by NUS service UUID, and reconnects.

### Persistence

| UserDefaults key | What it stores |
|---|---|
| `com.loopkit.Loop.DiaWatch.peripheralID` | Paired peripheral UUID |
| `com.loopkit.Loop.DiaWatch.deviceName` | Paired device name |
| `com.loopkit.Loop.DiaWatch.presets` | JSON-encoded preset array |
| `com.loopkit.Loop.DiaWatch.transmissionsEnabled` | Push readings toggle state |
| `com.loopkit.Loop.DiaWatch.lastSentTs` | Watermark — Unix seconds of the most recent reading the watch confirmed receiving |

Presets are persisted to UserDefaults only after the BLE transmission succeeds. On failure, the dirty flag stays true and Discard reverts to the last-known-good config.

### Source files

- `Loop/Managers/DiaWatchManager.swift` — all BLE logic, push trigger, pairing, timeout, preset management
- `Loop/Views/DiaWatchSettingsView.swift` — SwiftUI settings screen
- `Loop/Views/SettingsView.swift` — DiaWatch status indicator in main Settings list
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
| `.streaming` | Streaming... | yes |

### Scenario a) Correct transmission

| Status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged) |
| Sending... | ~0.5s | (unchanged) |
| Awaiting response... | ~1-2s | updates with watch output |
| OK, idle | final | timestamp updates to now |

### Scenario b) Connection OK, wrong response (watch returns error)

| Status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged) |
| Sending... | ~0.5s | (unchanged) |
| Awaiting response... | ~1-2s | updates with watch error output |
| Watch rejected ..., idle | final (orange) | timestamp updates to now |

### Scenario c) Connection OK, no response (watch is unresponsive)

| Status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged, stale) |
| Sending... | ~0.5s | (unchanged, stale) |
| Awaiting response... | 20s | no update |
| No echo from watch, idle | final (orange) | stale timestamp |

### Scenario d) Cannot connect (watch off or out of range)

| Status | Duration | Last response |
|---|---|---|
| Connecting... | up to 15s | (unchanged, stale) |
| Send timed out, idle | final (orange) | stale timestamp |

If BLE outright rejects the connection, the CoreBluetooth delegate callback `didFailToConnect` fires immediately:

| Status | Duration | Last response |
|---|---|---|
| Connecting... | instant | (unchanged) |
| Connection failed, idle | final (orange) | stale timestamp |

### Scenario e) REPL not ready (watch is booting)

| Status | Duration | Last response |
|---|---|---|
| Connecting... | ~1-3s | (unchanged, stale) |
| REPL not ready, idle | final (orange) | stale timestamp |

The prompt probe sent `\r` but no `>>>` arrived within 5 seconds. No payload was written — the boot sequence was not interrupted.

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
| 2 | Watch sends partial response then disconnects | Partially | If disconnect happens mid-send → "Disconnected mid-send, idle". If after chunks written but before `>>>` → caught by scenario 1. If `>>>` arrived but response is incomplete → currently marked OK |
| 3 | Watch responds with a Python traceback | Yes | `evaluateResult` uses case-insensitive check for "error" — Python tracebacks end with `...Error:` (e.g., `TypeError:`, `ValueError:`, `KeyError:`) so they are caught |
| 4 | Watch responds with MemoryError | Reported | "error" substring in response → per-command reject message + ", idle". Reading is left for the next push to retry (watermark not advanced) |
| 5 | No response at all within 20s | Yes | Response timer fires → disconnect → "No echo from watch, idle" |
| 6 | Cannot connect at all | Yes | 15s send timeout → "Send timed out, idle". Or immediate `didFailToConnect` → "Connection failed, idle" |
| 7 | REPL not ready (booting) | Yes | Prompt probe times out (5s) → "REPL not ready, idle". No payload sent |
| 8 | Correct transmission, watch confirms | Yes | "OK, idle" (green) |
| 9 | Watch responds with "ERROR" (any case) | Yes | `evaluateResult` catches case-insensitive "error" → per-command reject message + ", idle" (orange) |

### Last transmission response

The "Last transmission response" area in the Debug section shows the raw text received from the watch on the NUS TX characteristic during the most recent session. It includes the REPL echo, the watch's log output, and any error messages. A timestamp (e.g., "@ 14:23 16/4/2026") indicates when the last response byte arrived. If the timestamp is stale, the watch has not responded since that time.

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
2. **DiaWatch app is not active** — the `"app": "dw"` field in the message must be handled by the active watch application. If the watch is running a different app, it will not respond.
3. **Watch is connected to another device** — if the watch accepted our connection but is also trying to maintain a connection to another central, behaviour can be unpredictable.

### "Last push" stopped updating / error shown

- Check that Loop is still receiving CGM readings (main Loop status screen — if glucose is stale there, the problem is upstream of DiaWatch)
- Check the error text in the Status row for the specific failure message
- "REPL not ready" means the watch was booting or unresponsive — wait a few seconds and try again
- "Send timed out" means the watch accepted the BLE connection but stopped responding mid-sequence
- "No echo from watch" means data was sent but the watch never echoed it back
- "Watch did not complete execution" means the watch started processing but crashed (no `>>>` returned)
- If errors persist, tap **Forget device** and re-pair

### Readings appear on the watch but are delayed

This is expected behaviour. The push happens when Loop finishes processing the CGM reading, which is a few seconds after the sensor transmits it. The delay is the same as what Loop shows on its own status screen.

//
//  GlyWatchManager.swift
//  Loop
//

import CoreBluetooth
import Foundation
import HealthKit
import LoopKit

final class GlyWatchManager: NSObject, ObservableObject {

    // MARK: - BLE UUIDs

    static let nusServiceUUID = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let nusRXCharUUID  = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let nusTXCharUUID  = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    // MARK: - Haptic alert model

    /// What data the alert watches. The trigger picks the series, the
    /// condition tests it.
    enum AlertTrigger: String, Codable, CaseIterable {
        case datapoint = "dp"     // real reading series (24 slots, 5-min spaced); anchor = newest
        case forecast15 = "f15"   // forecast series (6 slots); anchor = +15 min
        case forecast30 = "f30"   // forecast series (6 slots); anchor = +30 min
        case outdated = "od"      // reading older than the preset's `od` minutes
        case noData = "nd"        // nothing at all for the preset's `nd` minutes

        var label: String {
            switch self {
            case .datapoint:  return "New reading"
            case .forecast15: return "New 15-min forecast"
            case .forecast30: return "New 30-min forecast"
            case .outdated:   return "Outdated data"
            case .noData:     return "No data"
            }
        }

        /// Freshness triggers take no condition, window or threshold.
        var isFreshness: Bool { self == .outdated || self == .noData }

        /// Forecast alerts never fire unless the preset has a forecaster set.
        var isForecast: Bool { self == .forecast15 || self == .forecast30 }

        /// How far past "now" the far edge of a window sits, in seconds.
        /// A window is a *total span* ending at this point, so an hour-long
        /// window on `f15` is 45 min of readings plus the 15 min forecast.
        var horizon: Int {
            switch self {
            case .forecast15: return 900
            case .forecast30: return 1800
            case .datapoint, .outdated, .noData: return 0
            }
        }
    }

    /// How the trigger's data is tested. `gt`/`lt` test the anchor point
    /// alone; the rest test a window of points.
    enum AlertCondition: String, Codable, CaseIterable {
        case gt, lt
        case avgGt = "avg_gt", avgLt = "avg_lt"
        case allGt = "all_gt", allLt = "all_lt"
        case anyGt = "any_gt", anyLt = "any_lt"

        var label: String {
            switch self {
            case .gt:    return "Above"
            case .lt:    return "Below"
            case .avgGt: return "Average above"
            case .avgLt: return "Average below"
            case .allGt: return "All above"
            case .allLt: return "All below"
            case .anyGt: return "Any above"
            case .anyLt: return "Any below"
            }
        }

        /// avg/all/any test the last `w // 300` readings (plus, on a forecast
        /// trigger, the forecast points up to the horizon). gt/lt forbid a
        /// window entirely.
        var isWindowed: Bool {
            switch self {
            case .gt, .lt: return false
            default:       return true
            }
        }

        var isAbove: Bool {
            switch self {
            case .gt, .avgGt, .allGt, .anyGt: return true
            default:                          return false
            }
        }
    }

    struct HapticAlert: Codable, Equatable, Identifiable {
        /// Exactly 3 alphanumeric characters, unique within the preset.
        /// User-visible on the watch (Alerts face and the ack screen), so it
        /// is meant to be readable — "lo1", "hi2", "f80" — not random.
        /// Companion-owned: the watch never generates ids and never detects
        /// collisions, and re-sending an existing id overwrites in place.
        var id: String
        /// Phone-side only, never on the wire: enabled sends `s_a`, disabled
        /// sends `d_a` (the watch forgets the alert either way).
        var enabled: Bool
        var trigger: AlertTrigger
        /// Required for dp/f15/f30, forbidden for od/nd.
        var condition: AlertCondition?
        /// Value in mg/dL to test against. Required except for od/nd.
        var value: Int?
        /// Window in seconds, 300...7200 in 300 s steps. Required for a
        /// windowed operator on `dp`, optional on a forecast trigger (nil =
        /// the forecast points alone), forbidden for gt/lt and od/nd.
        ///
        /// This is the *total span* of the window, ending at the trigger's
        /// horizon — not an amount of history. On `f15` a 1 h window is
        /// 45 min of readings plus the 15 min forecast; on `dp` it is a
        /// plain hour of readings. Either way the window holds
        /// `window / 300` points.
        var window: Int?
        /// Turn the screen on when the alert fires.
        var screenOn: Bool
        /// Haptic pattern name; nil = silent. Unknown names are accepted and
        /// stored by the watch but fire nothing.
        var pattern: String?
        /// Acknowledgment required: fullscreen "!" with the id, cleared by
        /// one tap or one button press.
        var ackRequired: Bool
        /// While un-acked, re-run the actions every `nagInterval` seconds.
        /// Minimum 60. nil = never remind. Shown in the UI as "Remind until
        /// acknowledged"; the property keeps its name because renaming it
        /// would change the Codable key and silently drop the stored value.
        var nagInterval: Int?
        /// Re-arm after this many seconds even if the condition still holds.
        /// Minimum 60. nil = edge-trigger, one fire per episode.
        var repeatInterval: Int?
        /// When several alerts match at once the highest priority fires, ties
        /// breaking to the smallest id. Higher number = higher priority.
        var priority: Int

        static let allPatterns: [String] = [
            "simple_pulse", "single_buzz", "single_buzz_short", "single_buzz_long", "double_buzz", "triple_buzz", "triple_tap",
            "heartbeat", "urgent", "linear_ramp", "short_long", "long_short",
            "double_tap", "notification", "notification_single", "bounce", "rbounce", "countdown",
            "stutter", "stutter_short", "stutter_long", "sos", "fanfare", "uprising_sweep"
        ]

        static let idLength = 3
        static let minWindow = 300
        static let maxWindow = 7200
        static let windowStep = 300
        /// `ins` and `rp` are minute-granularity on the watch.
        static let minInterval = 60

        static let defaultNew = HapticAlert(
            id: "",
            enabled: true,
            trigger: .datapoint,
            condition: .lt,
            value: 70,
            window: nil,
            screenOn: true,
            pattern: "single_buzz",
            ackRequired: false,
            nagInterval: nil,
            repeatInterval: nil,
            priority: 0
        )

        static func isValidId(_ id: String) -> Bool {
            id.count == idLength && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        /// Blocking problems. The watch rejects these with a logged error and
        /// saves nothing, so the companion refuses to send them at all.
        /// Mirrors the firmware's applicability matrix.
        var validationError: String? {
            guard Self.isValidId(id) else {
                return "ID must be exactly \(Self.idLength) letters or digits"
            }

            if trigger.isFreshness {
                if condition != nil { return "\(trigger.label) alerts take no condition" }
                if window != nil    { return "\(trigger.label) alerts take no window" }
                if value != nil     { return "\(trigger.label) alerts take no value" }
                return nil
            }

            guard let condition else { return "Pick a condition" }
            guard value != nil else { return "Pick a value" }

            if condition.isWindowed {
                // Required on `dp`: there is nothing else to bound the reading
                // series. Optional on a forecast trigger, where omitting it
                // means the forecast points alone — the same set of points as
                // `w == horizon`, so Loop always sends the explicit form.
                if trigger == .datapoint && window == nil {
                    return "\(condition.label) on a new reading needs a window"
                }
            } else if window != nil {
                return "\(condition.label) tests a single point — remove the window"
            }

            if let window {
                guard window >= Self.minWindow, window <= Self.maxWindow else {
                    return "Window must be between 5 min and 2 h"
                }
                guard window % Self.windowStep == 0 else {
                    return "Window must be a multiple of 5 min"
                }
                // The window ends at the horizon, so a shorter one would be a
                // tail slice of the forecast with no history. The watch does
                // not admit that.
                guard window >= trigger.horizon else {
                    return "Window must be at least the \(Self.formatDuration(trigger.horizon)) forecast horizon"
                }
            }
            if let nagInterval, nagInterval < Self.minInterval {
                return "Remind interval must be at least 1 min"
            }
            if let repeatInterval, repeatInterval < Self.minInterval {
                return "Repeat interval must be at least 1 min"
            }
            return nil
        }

        /// Non-blocking problems: the watch accepts these happily, but the
        /// alert may not do what the user expects.
        func warnings(forecaster: Forecaster) -> [String] {
            var out: [String] = []
            if trigger.isForecast && forecaster == .none {
                out.append("This preset has no forecaster, so a forecast alert never fires. Set one on the General tab.")
            }
            if ackRequired && !screenOn && nagInterval == nil {
                out.append("Acknowledgment is required, but the screen stays off and there is no reminder — this alert can go completely unnoticed.")
            }
            if pattern == nil && !screenOn {
                out.append("Silent with the screen off — this alert only ever shows on the watch's Alerts face.")
            }
            return out
        }

        /// e.g. "Below 70 mg/dL", "Average above 250 mg/dL over 2 h"
        var summary: String {
            switch trigger {
            case .outdated: return "Reading older than the preset's outdated threshold"
            case .noData:   return "No reading for the preset's no-data threshold"
            case .datapoint, .forecast15, .forecast30:
                guard let condition, let value else { return "Incomplete alert" }
                var text = "\(condition.label) \(value) mg/dL"
                if let window {
                    text += " over \(Self.formatDuration(window))"
                } else if condition.isWindowed {
                    text += " across the forecast"
                }
                return text
            }
        }

        /// e.g. "15-min forecast · Sos · Screen on · Ack · Repeat 30 min"
        var detail: String {
            var bits: [String] = [trigger.label, pattern.map(Self.formatPattern) ?? "Silent"]
            if screenOn { bits.append("Screen on") }
            if ackRequired { bits.append("Ack") }
            if let nagInterval { bits.append("Remind \(Self.formatDuration(nagInterval))") }
            if let repeatInterval { bits.append("Repeat \(Self.formatDuration(repeatInterval))") }
            if priority != 0 { bits.append("P\(priority)") }
            return bits.joined(separator: " · ")
        }

        /// Describe what a window actually covers, splitting the total span
        /// into its history and forecast parts.
        static func windowBreakdown(window: Int, trigger: AlertTrigger) -> String {
            let horizon = trigger.horizon
            if horizon == 0 {
                return "the last \(formatDuration(window)) of readings"
            }
            if window <= horizon {
                return "all the \(formatDuration(horizon)) forecast"
            }
            return "\(formatDuration(window - horizon)) of readings plus all the \(formatDuration(horizon)) forecast"
        }

        static func formatPattern(_ pat: String) -> String {
            pat.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }

        static func formatDuration(_ seconds: Int) -> String {
            let minutes = seconds / 60
            guard minutes >= 60 else { return "\(minutes) min" }
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        }
    }

    // MARK: - Preset model

    enum Forecaster: String, Codable, CaseIterable {
        case none
        case trend = "Trend"

        var label: String {
            switch self {
            case .none:       return "None"
            case .trend: return "Trend"
            }
        }
    }

    enum ButtonAndTapAction: Int, Codable, CaseIterable {
        case nothing = 0
        case wake = 1
        case haptics = 2

        var label: String {
            switch self {
            case .nothing: return "Nothing"
            case .wake:    return "Wake/Sleep"
            case .haptics: return "Haptics"
            }
        }
    }

    struct Preset: Codable, Equatable {
        var name: String
        var wakeOnReading: Bool
        var displayBrightness: Int   // 1, 2, 3
        var displayAlwaysOn: Bool    // when true, ds is emitted as null
        var displaySleepSec: Int     // seconds; only meaningful when !displayAlwaysOn
        var forecaster: Forecaster
        var od: Int      // outdated data threshold in minutes
        var nd: Int      // no data threshold in minutes
        var st: ButtonAndTapAction    // single tap action
        var dt: ButtonAndTapAction    // double tap action
        var lt: ButtonAndTapAction    // long tap action
        var sp: ButtonAndTapAction    // short press action
        var lp: ButtonAndTapAction    // long press action
        var rangeCutoffs: [Int]      // 4 ascending glucose cutoffs in mg/dL
        var rangeHaptics: [String]   // 5 haptic patterns, one per range
        var rangePlayHaptic: [Bool]  // 5 per-range flags: play haptic on new reading in that range
        var hapticAlerts: [HapticAlert]

        static let defaultRangeCutoffs: [Int] = [70, 100, 200, 300]
        static let defaultRangeHaptics: [String] = [
            "single_buzz", "notification", "notification_single", "stutter_short", "stutter"
        ]
        static let defaultRangePlayHaptic: [Bool] = [true, true, false, false, false]

        static let defaultPreset = Preset(
            name: "Default",
            wakeOnReading: false,
            displayBrightness: 2,
            displayAlwaysOn: false,
            displaySleepSec: 10,
            forecaster: .none,
            od: 10,
            nd: 30,
            st: .nothing,
            dt: .wake,
            lt: .nothing,
            sp: .wake,
            lp: .haptics,
            rangeCutoffs: defaultRangeCutoffs,
            rangeHaptics: defaultRangeHaptics,
            rangePlayHaptic: defaultRangePlayHaptic,
            hapticAlerts: []
        )

        init(name: String, wakeOnReading: Bool, displayBrightness: Int = 2, displayAlwaysOn: Bool = false, displaySleepSec: Int = 10, forecaster: Forecaster = .trend, od: Int = 10, nd: Int = 30, st: ButtonAndTapAction = .nothing, dt: ButtonAndTapAction = .wake, lt: ButtonAndTapAction = .nothing, sp: ButtonAndTapAction = .wake, lp: ButtonAndTapAction = .haptics, rangeCutoffs: [Int] = Preset.defaultRangeCutoffs, rangeHaptics: [String] = Preset.defaultRangeHaptics, rangePlayHaptic: [Bool] = Preset.defaultRangePlayHaptic, hapticAlerts: [HapticAlert] = []) {
            self.name = name
            self.wakeOnReading = wakeOnReading
            self.displayBrightness = displayBrightness
            self.displayAlwaysOn = displayAlwaysOn
            self.displaySleepSec = displaySleepSec
            self.forecaster = forecaster
            self.od = od
            self.nd = nd
            self.st = st
            self.dt = dt
            self.lt = lt
            self.sp = sp
            self.lp = lp
            self.rangeCutoffs = rangeCutoffs
            self.rangeHaptics = rangeHaptics
            self.rangePlayHaptic = rangePlayHaptic
            self.hapticAlerts = hapticAlerts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            wakeOnReading = try c.decode(Bool.self, forKey: .wakeOnReading)
            displayBrightness = try c.decodeIfPresent(Int.self, forKey: .displayBrightness) ?? 2
            displayAlwaysOn = try c.decodeIfPresent(Bool.self, forKey: .displayAlwaysOn) ?? false
            displaySleepSec = try c.decodeIfPresent(Int.self, forKey: .displaySleepSec) ?? 10
            forecaster = (try? c.decodeIfPresent(Forecaster.self, forKey: .forecaster)) ?? .trend
            od = try c.decodeIfPresent(Int.self, forKey: .od) ?? 10
            nd = try c.decodeIfPresent(Int.self, forKey: .nd) ?? 30
            st = (try? c.decodeIfPresent(ButtonAndTapAction.self, forKey: .st)) ?? .nothing
            dt = (try? c.decodeIfPresent(ButtonAndTapAction.self, forKey: .dt)) ?? .wake
            lt = (try? c.decodeIfPresent(ButtonAndTapAction.self, forKey: .lt)) ?? .nothing
            sp = (try? c.decodeIfPresent(ButtonAndTapAction.self, forKey: .sp)) ?? .wake
            lp = (try? c.decodeIfPresent(ButtonAndTapAction.self, forKey: .lp)) ?? .haptics
            rangeCutoffs = try c.decodeIfPresent([Int].self, forKey: .rangeCutoffs) ?? Preset.defaultRangeCutoffs
            rangeHaptics = try c.decodeIfPresent([String].self, forKey: .rangeHaptics) ?? Preset.defaultRangeHaptics
            rangePlayHaptic = try c.decodeIfPresent([Bool].self, forKey: .rangePlayHaptic) ?? Preset.defaultRangePlayHaptic
            // Resilient decode: any alerts from prior schema (no id field) fail
            // the whole array decode → fall back to empty. New format only.
            hapticAlerts = (try? c.decode([HapticAlert].self, forKey: .hapticAlerts)) ?? []
        }
    }

    // MARK: - Published state (drives settings UI)

    struct DiscoveredDevice: Identifiable {
        let peripheral: CBPeripheral
        let rssi: Int
        var id: UUID { peripheral.identifier }
        var name: String { peripheral.name ?? "Unknown" }
    }

    enum PushPhase: Equatable {
        case idle
        case connecting
        case sending
        case awaitingResponse
        case streaming
    }

    /// In-memory log entry for one BLE transmission. Capped to
    /// `maxLogEntries`, newest first. Not persisted.
    struct CommandLogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let command: String
        let status: String        // "OK" or short error reason
        let response: String      // full raw bleResponse at completion time
        let isUserTriggered: Bool // gray border = drain (false), blue = user (true)
        var isError: Bool { status != "OK" }
    }

    @Published var pairedDeviceName: String?
    @Published var lastPushDate: Date?
    @Published var lastPushValue: Int?
    @Published var lastPushReadingDate: Date?
    @Published var lastPushError: String?
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var pushPhase: PushPhase = .idle
    @Published var lastResponseDate: Date?
    @Published var hasTransmitted: Bool = false
    @Published var isStreaming: Bool = false
    @Published var presets: [Preset] = UserDefaults.standard.glyWatchPresets
    @Published var bleResponse: String = ""
    @Published var pendingReadingsCount: Int = 0
    @Published var commandLog: [CommandLogEntry] = []
    /// Progress of a running `resendAlerts` run. `alertResendTotal == 0`
    /// means no re-send is in flight. Each alert is its own BLE connect,
    /// so a run of any size takes long enough to be worth showing.
    @Published var alertResendSent: Int = 0
    @Published var alertResendTotal: Int = 0
    @Published var transmissionsEnabled: Bool = UserDefaults.standard.glyWatchTransmissionsEnabled {
        didSet {
            UserDefaults.standard.glyWatchTransmissionsEnabled = transmissionsEnabled
            if !transmissionsEnabled { transmissionQueue = [] }
        }
    }

    // MARK: - Private state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var isSending = false
    private var lastSentMgdl: Int = 0
    private var onTransmissionComplete: (() -> Void)?
    private var receivedResponse = false
    private var responseSessionStarted = false
    private var replPromptCount = 0
    private var transmissionQueue: [(message: String, onComplete: (() -> Void)?, isUserTriggered: Bool)] = []
    private var scanTimer: Timer?
    private var sendTimeoutTimer: Timer?
    private static let sendTimeout: TimeInterval = 15
    private var responseTimer: Timer?
    private static let responseInitialTimeout: TimeInterval = 20  // max wait for first byte
    private static let responseIdleTimeout: TimeInterval = 5      // disconnect after this much silence
    private var waitingForPrompt: Bool = false
    private var sentCtrlC: Bool = false
    /// Accumulates every byte received during the probe phase (initial \r and
    /// any Ctrl-C escalation), captured separately so it survives the
    /// bleResponse clear that happens on >>> detection. Logged as its own
    /// CommandLogEntry at probe completion.
    private var probeResponse: String = ""
    private var promptTimer: Timer?
    private static let promptTimeout: TimeInterval = 5
    private var pendingCommandEcho: String?   // command text the REPL will echo back (no \r\n)
    private var echoDetected = false          // true once pendingCommandEcho seen in TX stream
    private var chunkIndex: Int = 0           // 0-based index of next chunk to write
    private var chunkTotal: Int = 0           // total chunks in current transmission

    // Reading-drain state. Backfill cap of 2h prevents flooding the watch
    // after long offline periods. lastSentTs is persisted so the watermark
    // survives app restarts.
    static let maxBackfillInterval: TimeInterval = 2 * 60 * 60
    private var isDrainingReadings = false

    // Command-log state. Captured at beginTransmission time, snapshotted
    // into a CommandLogEntry when the transmission resolves (success,
    // failure, or abort).
    private static let maxLogEntries = 1000
    private var currentLogCommand: String?
    private var currentLogIsUserTriggered: Bool = false

    private weak var deviceManager: DeviceDataManager?
    private let log = DiagnosticLog(category: "GlyWatchManager")

    // MARK: - Init

    init(deviceManager: DeviceDataManager) {
        self.deviceManager = deviceManager
        self.pairedDeviceName = UserDefaults.standard.glyWatchDeviceName
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loopkit.GlyWatchManager"]
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLoopDataUpdated(_:)),
            name: .LoopDataUpdated,
            object: nil
        )
    }

    // MARK: - Notification handler

    @objc private func onLoopDataUpdated(_ notification: Notification) {
        guard
            let raw = notification.userInfo?[LoopDataManager.LoopUpdateContextKey] as? LoopDataManager.LoopUpdateContext.RawValue,
            let context = LoopDataManager.LoopUpdateContext(rawValue: raw),
            case .glucose = context
        else { return }
        refreshPendingReadingsCount()
        push()
    }

    /// Recomputes the number of glucose samples in the 2h window with
    /// startDate strictly newer than the watermark. Async; updates
    /// `pendingReadingsCount` on the main queue.
    func refreshPendingReadingsCount() {
        guard let dm = deviceManager else { return }
        let now = Date()
        let cap = Int(now.addingTimeInterval(-Self.maxBackfillInterval).timeIntervalSince1970)
        let lastSent = UserDefaults.standard.glyWatchLastSentTs
        let floor = max(lastSent, cap)
        let floorDate = Date(timeIntervalSince1970: TimeInterval(floor))
        dm.glucoseStore.getGlucoseSamples(start: floorDate, end: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let samples) = result {
                    let lastSentNow = UserDefaults.standard.glyWatchLastSentTs
                    self.pendingReadingsCount = samples.filter {
                        Int($0.startDate.timeIntervalSince1970) > lastSentNow
                    }.count
                }
            }
        }
    }

    // MARK: - Transmission result evaluation

    private func evaluateResult(rejectMessage: String) {
        if !receivedResponse {
            lastPushError = "No response from watch"
        } else if echoDetected && replPromptCount == 0 {
            lastPushError = "Watch did not complete execution"
        } else if bleResponse.range(of: "error", options: .caseInsensitive) != nil {
            lastPushError = rejectMessage
        } else {
            lastPushError = nil
        }
    }

    // MARK: - Push (glucose reading)

    func push() {
        guard transmissionsEnabled, UserDefaults.standard.glyWatchPeripheralID != nil else { return }
        drainReadings()
    }

    func pushTest(mgdl: Int = 190) {
        // Debug helper: bypasses the drain and watermark, sends a synthetic
        // reading at the current time. Watch will silently dedup if older
        // than its own last received ts.
        sendOneOffReading(mgdl: mgdl, trend: "f", ts: Int(Date().timeIntervalSince1970))
    }

    func resetReadingsWatermark() {
        UserDefaults.standard.glyWatchLastSentTs = 0
        log.default("GlyWatch readings watermark reset to 0")
        refreshPendingReadingsCount()
    }

    func drainReadings() {
        guard !isDrainingReadings else { return }
        guard let dm = deviceManager else { return }

        let now = Date()
        let cap = Int(now.addingTimeInterval(-Self.maxBackfillInterval).timeIntervalSince1970)
        let lastSent = UserDefaults.standard.glyWatchLastSentTs
        let floor = max(lastSent, cap)
        let floorDate = Date(timeIntervalSince1970: TimeInterval(floor))

        isDrainingReadings = true
        dm.glucoseStore.getGlucoseSamples(start: floorDate, end: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.log.error("GlyWatch drain query failed: %{public}@", String(describing: error))
                    self.isDrainingReadings = false
                case .success(let samples):
                    let unsent = samples.filter { Int($0.startDate.timeIntervalSince1970) > UserDefaults.standard.glyWatchLastSentTs }
                    self.pendingReadingsCount = unsent.count
                    if unsent.isEmpty {
                        self.isDrainingReadings = false
                        return
                    }
                    self.log.default("GlyWatch draining %{public}d unsent reading(s)", unsent.count)
                    self.sendNextInDrain(unsent[...])
                }
            }
        }
    }

    private func sendNextInDrain(_ remaining: ArraySlice<StoredGlucoseSample>) {
        guard let sample = remaining.first else {
            isDrainingReadings = false
            // Re-check: a new sample may have arrived during this drain;
            // its notification was no-op'd by the re-entry guard. The
            // re-query returns empty if nothing new, clearing the flag.
            drainReadings()
            return
        }
        let mgdl = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
        let trend = glyWatchTrend(from: deviceManager?.glucoseDisplay(for: sample)?.trendType)
        let ts = Int(sample.startDate.timeIntervalSince1970)
        let bf = remaining.count > 1 ? "true" : "false"
        let message = "GB({\"app\":\"gly\",\"t\":\"r\",\"v\":\(mgdl),\"tr\":\"\(trend)\",\"ts\":\(ts),\"bf\":\(bf)})\r\n"
        log.default("Sending GlyWatch reading: %{public}@", message)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Unexpected watch response")
            let confirmed = self.lastPushError == nil && self.bleResponse.contains("reading received")
            if self.lastPushError == nil && !confirmed {
                self.lastPushError = "Unexpected watch response"
            }
            if confirmed {
                UserDefaults.standard.glyWatchLastSentTs = ts
                self.lastSentMgdl = mgdl
                self.lastPushDate = Date()
                self.lastPushValue = mgdl
                self.lastPushReadingDate = sample.startDate
                self.pendingReadingsCount = max(0, self.pendingReadingsCount - 1)
                self.log.default("GlyWatch push complete (ts=%{public}d)", ts)
                self.sendNextInDrain(remaining.dropFirst())
            } else {
                // Stop the drain. Next LoopDataUpdated.glucose notification
                // will re-query from the un-advanced watermark and retry
                // this sample plus anything newer.
                self.isDrainingReadings = false
                self.log.default("GlyWatch reading send failed; drain paused, will retry on next notification")
            }
        }
    }

    private func sendOneOffReading(mgdl: Int, trend: String, ts: Int) {
        let message = "GB({\"app\":\"gly\",\"t\":\"r\",\"v\":\(mgdl),\"tr\":\"\(trend)\",\"ts\":\(ts),\"bf\":false})\r\n"
        lastSentMgdl = mgdl
        log.default("Sending GlyWatch reading (test): %{public}@", message)
        let readingDate = Date(timeIntervalSince1970: TimeInterval(ts))
        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.lastPushDate = Date()
            self.lastPushValue = self.lastSentMgdl
            self.lastPushReadingDate = readingDate
            self.evaluateResult(rejectMessage: "Unexpected watch response")
            if self.lastPushError == nil && !self.bleResponse.contains("reading received") {
                self.lastPushError = "Unexpected watch response"
            }
            self.log.default("GlyWatch test push complete")
        }
    }

    // MARK: - Preset management

    func saveRanges(at index: Int) {
        guard !isSending, index < presets.count else { return }

        let preset = presets[index]
        let rcJSON = "[" + preset.rangeCutoffs.map(String.init).joined(separator: ",") + "]"
        let rhJSON = "[" + preset.rangeHaptics.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let phJSON = "[" + preset.rangePlayHaptic.map { $0 ? "1" : "0" }.joined(separator: ",") + "]"
        let rangesMsg = "GB({\"app\":\"gly\",\"t\":\"s_r\",\"p\":\(index),\"rc\":\(rcJSON),\"rh\":\(rhJSON),\"ph\":\(phJSON)})\r\n"

        log.default("Sending GlyWatch preset %{public}d ranges", index)
        beginTransmission(rangesMsg, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected ranges")
            if self.lastPushError == nil { UserDefaults.standard.glyWatchPresets = self.presets }
            self.log.default("GlyWatch preset %{public}d ranges saved", index)
        }
    }

    func saveGeneralConfig(at index: Int) {
        guard !isSending, index < presets.count else { return }

        let preset = presets[index]
        let dsValue = preset.displayAlwaysOn ? "null" : "\(preset.displaySleepSec)"
        let fcValue = preset.forecaster == .none ? "null" : "\"\(preset.forecaster.rawValue)\""
        let configMsg = "GB({\"app\":\"gly\",\"t\":\"s_c\",\"p\":\(index),\"n\":\(Self.quoted(preset.name)),\"rw\":\(preset.wakeOnReading ? 1 : 0),\"db\":\(preset.displayBrightness),\"ds\":\(dsValue),\"fc\":\(fcValue),\"od\":\(preset.od),\"nd\":\(preset.nd),\"st\":\(preset.st.rawValue),\"dt\":\(preset.dt.rawValue),\"lt\":\(preset.lt.rawValue),\"sp\":\(preset.sp.rawValue),\"lp\":\(preset.lp.rawValue)})\r\n"

        log.default("Sending GlyWatch preset %{public}d general config", index)
        beginTransmission(configMsg, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected preset config")
            if self.lastPushError == nil { UserDefaults.standard.glyWatchPresets = self.presets }
            self.log.default("GlyWatch preset %{public}d general config saved", index)
        }
    }

    /// Render free text as a quoted string literal for a `GB(...)` line.
    ///
    /// The watch's REPL evaluates the line as Python, so a raw `"` would end
    /// the string early and a raw `\` would start an escape. Both are
    /// backslash-escaped, which reads the same as JSON and as Python.
    /// Control characters are dropped: a newline would end the REPL line.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default:
                if scalar.value >= 0x20 && scalar.value != 0x7F {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Build the `s_a` line for one alert.
    ///
    /// Keys the firmware treats as FORBIDDEN for a given trigger/condition
    /// are omitted outright rather than sent as null — an omitted optional
    /// key and an explicit null mean the same thing to the watch, and
    /// omitting keeps the line comfortably inside the ~256-byte REPL buffer.
    private static func alertMessage(presetIndex: Int, alert: HapticAlert) -> String {
        var fields: [String] = [
            "\"app\":\"gly\"",
            "\"t\":\"s_a\"",
            "\"p\":\(presetIndex)",
            "\"id\":\"\(alert.id)\"",
            "\"tr\":\"\(alert.trigger.rawValue)\"",
        ]
        if let condition = alert.condition { fields.append("\"c\":\"\(condition.rawValue)\"") }
        if let window = alert.window       { fields.append("\"w\":\(window)") }
        if let value = alert.value         { fields.append("\"v\":\(value)") }
        fields.append("\"so\":\(alert.screenOn ? 1 : 0)")
        fields.append("\"pat\":\(alert.pattern.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"ack\":\(alert.ackRequired ? 1 : 0)")
        fields.append("\"ins\":\(alert.nagInterval.map(String.init) ?? "null")")
        fields.append("\"rp\":\(alert.repeatInterval.map(String.init) ?? "null")")
        fields.append("\"pr\":\(alert.priority)")
        return "GB({" + fields.joined(separator: ",") + "})\r\n"
    }

    /// The watch evaluates each line in a ~256-byte REPL buffer; anything
    /// longer is truncated into a syntax error rather than rejected cleanly.
    private static let maxCommandBytes = 250

    /// Save (or disable) a single alert.
    ///
    /// Wire behaviour:
    /// - `alert.enabled == true`  → send `s_a` with the full field set
    /// - `alert.enabled == false` → send `d_a` (the watch forgets it)
    /// - Special case: if the alert is **new** AND already disabled at save
    ///   time, BLE is skipped entirely — `d_a` for an id the watch has never
    ///   seen is a no-op, so the round-trip is waste. The alert is just
    ///   stored locally with `enabled=false`.
    ///
    /// Local behaviour:
    /// - On BLE success → upsert with the alert exactly as supplied.
    /// - On BLE failure → upsert with `enabled` forced to `false`. The user's
    ///   field values are still persisted, so they can retry without
    ///   re-entering them, and the alert state correctly reflects that the
    ///   watch does NOT have it active.
    /// - Removal from the phone-side list only happens via `deleteAlert`.
    ///
    /// `isNew` cannot be inferred from the id: an edit keeps its id (the id
    /// is immutable once saved, since renaming would orphan the watch-side
    /// file), so "id already in the list" means *update* for an edit and
    /// *collision* for a new alert.
    func saveAlert(at presetIndex: Int, alert: HapticAlert, isNew: Bool, onResult: ((Bool, String?) -> Void)? = nil) {
        guard !isSending, presetIndex < presets.count else {
            onResult?(false, "Busy or invalid preset")
            return
        }

        // Validate before touching BLE: the watch rejects a bad payload with
        // nothing but a log line, so a round-trip would tell the user less
        // than we already know here.
        if let problem = alert.validationError {
            log.error("Refusing to send GlyWatch alert %{public}@: %{public}@", alert.id, problem)
            onResult?(false, problem)
            return
        }

        let existsLocally = presets[presetIndex].hapticAlerts.contains { $0.id == alert.id }
        if isNew && existsLocally {
            // The watch overwrites blindly on a repeated id and never reports
            // a collision, so an unchecked duplicate would silently clobber
            // the other alert on the device.
            onResult?(false, "An alert with ID \u{201C}\(alert.id)\u{201D} already exists in this preset")
            return
        }

        if !alert.enabled && !existsLocally {
            // New + disabled: nothing to push to the watch, just store locally.
            log.default("GlyWatch alert id=%{public}@ created locally, disabled — skipping BLE", alert.id)
            presets[presetIndex].hapticAlerts.append(alert)
            UserDefaults.standard.glyWatchPresets = presets
            onResult?(true, nil)
            return
        }

        let message: String
        if alert.enabled {
            message = Self.alertMessage(presetIndex: presetIndex, alert: alert)
            log.default("Saving GlyWatch alert id=%{public}@ in preset %{public}d", alert.id, presetIndex)
        } else {
            message = "GB({\"app\":\"gly\",\"t\":\"d_a\",\"p\":\(presetIndex),\"id\":\"\(alert.id)\"})\r\n"
            log.default("Disabling GlyWatch alert id=%{public}@ in preset %{public}d (sending d_a, keeping locally)", alert.id, presetIndex)
        }

        guard message.utf8.count <= Self.maxCommandBytes else {
            onResult?(false, "Alert is too long for the watch (\(message.utf8.count) bytes)")
            return
        }

        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected alert")
            // Upsert in both success and failure cases. On failure force
            // enabled=false so local state reflects "watch does NOT have it
            // active right now" — the user keeps their settings and can retry.
            var stored = alert
            if self.lastPushError != nil { stored.enabled = false }
            if let i = self.presets[presetIndex].hapticAlerts.firstIndex(where: { $0.id == alert.id }) {
                self.presets[presetIndex].hapticAlerts[i] = stored
            } else {
                self.presets[presetIndex].hapticAlerts.append(stored)
            }
            UserDefaults.standard.glyWatchPresets = self.presets
            if self.lastPushError == nil {
                self.log.default("GlyWatch alert %{public}@ saved", alert.id)
                onResult?(true, nil)
            } else {
                self.log.default("GlyWatch alert %{public}@ save failed; stored locally as disabled", alert.id)
                onResult?(false, self.lastPushError)
            }
        }
    }

    /// Tell the watch to drop the alert with this id, then remove it locally.
    func deleteAlert(at presetIndex: Int, alertId: String, onResult: ((Bool, String?) -> Void)? = nil) {
        guard !isSending, presetIndex < presets.count else {
            onResult?(false, "Busy or invalid preset")
            return
        }
        let message = "GB({\"app\":\"gly\",\"t\":\"d_a\",\"p\":\(presetIndex),\"id\":\"\(alertId)\"})\r\n"
        log.default("Deleting GlyWatch alert id=%{public}@ in preset %{public}d", alertId, presetIndex)
        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected alert delete")
            if self.lastPushError == nil {
                self.presets[presetIndex].hapticAlerts.removeAll { $0.id == alertId }
                UserDefaults.standard.glyWatchPresets = self.presets
                self.log.default("GlyWatch alert %{public}@ deleted", alertId)
                onResult?(true, nil)
            } else {
                onResult?(false, self.lastPushError)
            }
        }
    }

    /// Re-push every enabled alert in the preset, one command per connection,
    /// stopping at the first failure.
    ///
    /// There is no list-alerts command and the watch drops alert files it
    /// cannot parse (a firmware update did exactly that to every alert stored
    /// under an older schema), so the phone is the only source of truth for
    /// what should exist on the device. This is how the two are reconciled.
    func resendAlerts(at presetIndex: Int, onResult: ((Bool, String?) -> Void)? = nil) {
        guard !isSending, presetIndex < presets.count else {
            onResult?(false, "Busy or invalid preset")
            return
        }
        let pending = presets[presetIndex].hapticAlerts.filter { $0.enabled }
        guard !pending.isEmpty else {
            onResult?(false, "No enabled alerts to send")
            return
        }
        log.default("Re-sending %{public}d GlyWatch alerts in preset %{public}d", pending.count, presetIndex)
        alertResendSent = 0
        alertResendTotal = pending.count
        sendAlertChain(presetIndex: presetIndex, remaining: pending, sent: 0, total: pending.count, onResult: onResult)
    }

    private func sendAlertChain(presetIndex: Int, remaining: [HapticAlert], sent: Int, total: Int, onResult: ((Bool, String?) -> Void)?) {
        guard let alert = remaining.first else {
            log.default("GlyWatch re-send complete (%{public}d alerts)", sent)
            alertResendTotal = 0
            onResult?(true, nil)
            return
        }
        let rest = Array(remaining.dropFirst())

        // Skip rather than abort: one unsendable alert should not block the
        // rest of the preset from being restored on the watch.
        if let problem = alert.validationError {
            log.error("Skipping GlyWatch alert %{public}@ during re-send: %{public}@", alert.id, problem)
            sendAlertChain(presetIndex: presetIndex, remaining: rest, sent: sent, total: total, onResult: onResult)
            return
        }

        beginTransmission(Self.alertMessage(presetIndex: presetIndex, alert: alert), isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected alert \(alert.id)")
            if self.lastPushError == nil {
                self.alertResendSent = sent + 1
                self.sendAlertChain(presetIndex: presetIndex, remaining: rest, sent: sent + 1, total: total, onResult: onResult)
            } else {
                self.alertResendTotal = 0
                onResult?(false, "Stopped at \(alert.id) after \(sent)/\(total): \(self.lastPushError ?? "failed")")
            }
        }
    }

    /// Generate a 3-char lowercase alphanumeric id that does not collide with
    /// any existing alert in the preset. 36^3 = 46,656 namespace — practically
    /// no contention even at hundreds of alerts.
    ///
    /// The watch never generates ids and never detects collisions, so
    /// uniqueness is entirely the companion's job.
    func generateUniqueAlertId(forPresetAt index: Int) -> String {
        guard index < presets.count else { return Self.randomAlertId() }
        let existing = Set(presets[index].hapticAlerts.map { $0.id })
        for _ in 0..<100 {
            let candidate = Self.randomAlertId()
            if !existing.contains(candidate) { return candidate }
        }
        return Self.randomAlertId()
    }

    private static func randomAlertId() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<3).compactMap { _ in chars.randomElement() })
    }

    static let maxPresets = 4
    /// Keeps the `s_c` line well inside `maxCommandBytes` even when every
    /// character needs escaping, and the "<name> mode" label short enough
    /// for the watch face.
    static let maxPresetNameLength = 16

    func addPreset() {
        guard presets.count < Self.maxPresets else { return }
        let newPreset = Preset(
            name: "Preset \(presets.count)",
            wakeOnReading: false
        )
        presets.append(newPreset)
    }

    func duplicatePreset(at index: Int) {
        guard index < presets.count, presets.count < Self.maxPresets else { return }
        var copy = presets[index]
        let suffix = " copy"
        copy.name = String(copy.name.prefix(Self.maxPresetNameLength - suffix.count)) + suffix
        presets.append(copy)
    }

    func deleteLastPreset() {
        guard presets.count > 1, !isSending else { return }

        let lastIdx = presets.count - 1
        let isPersistedToPhone = lastIdx < UserDefaults.standard.glyWatchPresets.count

        presets.removeLast()
        UserDefaults.standard.glyWatchPresets = presets

        // If the preset was never saved to the phone, the watch doesn't know about it
        guard isPersistedToPhone else { return }

        log.default("Deleting GlyWatch preset %{public}d", lastIdx)
        beginTransmission("GB({\"app\":\"gly\",\"t\":\"d_p\",\"p\":\(lastIdx)})\r\n", isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected preset delete")
            self.log.default("GlyWatch preset %{public}d deleted", lastIdx)
        }
    }

    func activatePreset(at index: Int) {
        guard !isSending, index < presets.count else { return }
        let message = "GB({\"app\":\"gly\",\"t\":\"a_p\",\"p\":\(index)})\r\n"
        log.default("Activating GlyWatch preset %{public}d", index)
        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected preset activation")
        }
    }

    // MARK: - Set time

    func setTime() {
        guard !isSending else { return }
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let y  = cal.component(.year,   from: now)
        let mo = cal.component(.month,  from: now)
        let d  = cal.component(.day,    from: now)
        let h  = cal.component(.hour,   from: now)
        let mi = cal.component(.minute, from: now)
        let s  = cal.component(.second, from: now)
        let ff = TimeZone.current.secondsFromGMT(for: now)  // DST-aware

        let message = "GB({\"app\":\"gly\",\"t\":\"s_t\",\"lt\":[\(y),\(mo),\(d),\(h),\(mi),\(s)],\"ff\":\(ff)})\r\n"
        log.default("Setting GlyWatch time: lt=[%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d] ff=%{public}d",
                    y, mo, d, h, mi, s, ff)
        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected set time")
            self.log.default("GlyWatch set time complete")
        }
    }

    // MARK: - Custom command

    func sendCustomCommand(_ text: String) {
        guard !isSending, !text.isEmpty else { return }
        let message = text.hasSuffix("\r\n") ? text : text + "\r\n"
        log.default("Sending GlyWatch custom command: %{public}@", text)
        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.lastPushError = self.receivedResponse ? nil : "No response from watch"
            self.log.default("GlyWatch custom command complete")
        }
    }

    // MARK: - Log stream

    func startLogStream() {
        guard !isSending, !isStreaming else { return }
        isStreaming = true
        bleResponse = ""
        pushPhase = .connecting
        connectOrScan()
    }

    func stopLogStream() {
        guard isStreaming else { return }
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        // isStreaming is cleared in didDisconnectPeripheral
    }

    // MARK: - Haptic test

    func testHaptic(name: String) {
        guard !isSending else { return }
        let message = "from utils import Haptics; Haptics.\(name)()\r\n"
        log.default("Sending GlyWatch test haptic: %{public}@", name)
        beginTransmission(message, isUserTriggered: true) { [weak self] in
            guard let self else { return }
            self.lastPushError = self.receivedResponse ? nil : "No response from watch"
            self.log.default("GlyWatch test haptic complete")
        }
    }

    // MARK: - Base transmission

    private func beginTransmission(_ message: String, isUserTriggered: Bool = false, onComplete: (() -> Void)? = nil) {
        guard !isSending else {
            if transmissionsEnabled {
                log.default("GlyWatch enqueue (busy) [%{public}d bytes]: %{public}@", message.utf8.count, message)
                transmissionQueue.append((message: message, onComplete: onComplete, isUserTriggered: isUserTriggered))
            }
            return
        }

        // Pre-flight log capture so failWithoutSending can still log an entry.
        currentLogCommand = message
        currentLogIsUserTriggered = isUserTriggered

        guard UserDefaults.standard.glyWatchPeripheralID != nil else {
            failWithoutSending(error: "No device paired")
            return
        }

        // Every command goes through here, so this is the one place that
        // keeps an oversized line (e.g. `s_c` with a long preset name) from
        // being truncated into a syntax error on the watch.
        guard message.utf8.count <= Self.maxCommandBytes else {
            log.error("Refusing to send GlyWatch command of %{public}d bytes (max %{public}d)", message.utf8.count, Self.maxCommandBytes)
            failWithoutSending(error: "Command is too long for the watch (\(message.utf8.count) bytes)")
            return
        }

        guard let msgData = message.data(using: .utf8) else { return }

        log.default("GlyWatch TX [%{public}d bytes]: %{public}@", message.utf8.count, message)

        pendingCommandEcho = message.trimmingCharacters(in: .whitespacesAndNewlines)
        echoDetected = false
        pendingChunks = stride(from: 0, to: msgData.count, by: 20).map {
            Data(msgData[$0 ..< min($0 + 20, msgData.count)])
        }
        chunkTotal = pendingChunks.count
        chunkIndex = 0

        isSending = true
        onTransmissionComplete = onComplete
        receivedResponse = false
        responseSessionStarted = false
        replPromptCount = 0
        pushPhase = .connecting
        startSendTimeout()
        connectOrScan()
    }

    /// Fail a command that never reaches BLE (no paired device, or a line
    /// too long for the watch). The phase still goes connecting → idle,
    /// because the settings screen reads the outcome on the return to idle.
    /// The command's completion is not called.
    private func failWithoutSending(error: String) {
        isSending = true
        pushPhase = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lastPushError = error
            self.appendCurrentCommandLogEntry(status: error, response: "")
            self.isSending = false
            self.isDrainingReadings = false
            self.alertResendTotal = 0
            self.hasTransmitted = true
            self.pushPhase = .idle
        }
    }

    /// Snapshot the current transmission's captured fields into a log entry
    /// and prepend it. Clears `currentLogCommand` so re-entrant
    /// beginTransmission calls (e.g. drain advancing) don't double-log.
    private func appendCurrentCommandLogEntry(status: String, response: String) {
        guard let cmd = currentLogCommand else { return }
        let entry = CommandLogEntry(
            timestamp: Date(),
            command: cmd,
            status: status,
            response: response,
            isUserTriggered: currentLogIsUserTriggered
        )
        currentLogCommand = nil
        commandLog.insert(entry, at: 0)
        if commandLog.count > Self.maxLogEntries {
            commandLog.removeLast(commandLog.count - Self.maxLogEntries)
        }
    }

    private func startSendTimeout() {
        sendTimeoutTimer?.invalidate()
        sendTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.sendTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isSending else { return }
            self.log.error("GlyWatch send timed out after %{public}g s", Self.sendTimeout)
            self.abortSend(error: "Send timed out")
        }
    }

    private func cancelSendTimeout() {
        sendTimeoutTimer?.invalidate()
        sendTimeoutTimer = nil
    }

    private func armResponseTimer(delay: TimeInterval) {
        responseTimer?.invalidate()
        responseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let p = self.peripheral else { return }
            self.log.default("GlyWatch response timer fired — disconnecting")
            self.central.cancelPeripheralConnection(p)
        }
    }

    private func cancelResponseTimer() {
        responseTimer?.invalidate()
        responseTimer = nil
    }

    private func abortSend(error: String) {
        cancelSendTimeout()
        cancelResponseTimer()
        cancelPromptTimer()
        waitingForPrompt = false
        sentCtrlC = false
        isStreaming = false
        isSending = false
        isDrainingReadings = false
        pendingChunks = []
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rxCharacteristic = nil
        onTransmissionComplete = nil
        transmissionQueue = []
        pendingCommandEcho = nil
        echoDetected = false
        appendCurrentCommandLogEntry(status: error, response: bleResponse)
        lastPushError = error
        hasTransmitted = true
        pushPhase = .idle
    }

    private func connectOrScan() {
        guard central.state == .poweredOn else { return }

        if let id = UserDefaults.standard.glyWatchPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            central.connect(known, options: nil)
        } else {
            // Paired UUID not in CB cache — fall back to scan
            central.scanForPeripherals(withServices: [Self.nusServiceUUID], options: nil)
        }
    }

    // MARK: - Pairing (UI-driven)

    func startScan() {
        guard central.state == .poweredOn, !isScanning else { return }
        discoveredDevices = []
        isScanning = true
        // nil = show all nearby BLE devices so the user can identify their watch
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
    }

    func pair(_ device: DiscoveredDevice) {
        stopScan()
        UserDefaults.standard.glyWatchPeripheralID = device.peripheral.identifier
        UserDefaults.standard.glyWatchDeviceName = device.peripheral.name
        pairedDeviceName = device.peripheral.name
        log.default("Paired GlyWatch device: %{public}@ (%{public}@)", device.name, device.peripheral.identifier.uuidString)
    }

    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rxCharacteristic = nil
        isSending = false
        pendingChunks = []
        onTransmissionComplete = nil
        UserDefaults.standard.glyWatchPeripheralID = nil
        UserDefaults.standard.glyWatchDeviceName = nil
        pairedDeviceName = nil
        lastPushDate = nil
        lastPushValue = nil
        lastPushReadingDate = nil
        lastPushError = nil
        bleResponse = ""
        log.default("Forgot GlyWatch device")
    }

    // MARK: - REPL prompt probe

    private enum PromptKind { case ready, continuation, none }

    /// Scans the buffer for the LAST prompt token (>>> or ...). The last one
    /// reflects the REPL's current state — earlier ones may be stale from a
    /// previous traceback or from string content.
    private func lastPromptIn(_ buffer: String) -> PromptKind {
        let lastReady = buffer.range(of: ">>>", options: .backwards)
        let lastCont  = buffer.range(of: "...", options: .backwards)
        switch (lastReady, lastCont) {
        case (nil, nil):   return .none
        case (_, nil):     return .ready
        case (nil, _):     return .continuation
        case let (r?, c?): return r.lowerBound > c.lowerBound ? .ready : .continuation
        }
    }

    private func probeForPrompt() {
        guard let p = peripheral, let rx = rxCharacteristic else { return }

        waitingForPrompt = true
        sentCtrlC = false
        // Clear stale buffer from any prior session so the prompt scan only
        // sees what the watch actually sends in response to our \r.
        bleResponse = ""
        probeResponse = ""

        // Send a bare \r to solicit a prompt. If the REPL is at >>>, we
        // proceed. If it answers with ... (continuation prompt — stuck in
        // a multi-line input), we send Ctrl-C twice + \r to break out and
        // wait for >>>. If the watch is booting, no prompt arrives and we
        // time out safely instead of interrupting the boot sequence.
        log.default("GlyWatch probing for REPL prompt (sending \\r)")
        p.writeValue(Data([0x0D]), for: rx, type: .withResponse)

        startPromptTimer()
    }

    private func sendCtrlCBreak() {
        guard let p = peripheral, let rx = rxCharacteristic else { return }
        log.default("GlyWatch continuation prompt detected — sending \\x03\\x03 + \\r")
        sentCtrlC = true
        bleResponse = ""
        p.writeValue(Data([0x03, 0x03, 0x0D]), for: rx, type: .withResponse)
        cancelPromptTimer()
        startPromptTimer()
    }

    private func startPromptTimer() {
        promptTimer = Timer.scheduledTimer(withTimeInterval: Self.promptTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.promptTimer = nil
            if self.waitingForPrompt {
                self.waitingForPrompt = false
                self.log.default("GlyWatch REPL prompt not received within %{public}.0f s", Self.promptTimeout)
                self.appendProbeLogEntry(status: self.sentCtrlC ? "Stuck in continuation" : "REPL not ready")
                self.abortSend(error: "REPL not ready")
            }
        }
    }

    /// Build the probe's "command" representation for the log card: bare \r,
    /// or "\r → \x03\x03\r" if Ctrl-C escalation happened.
    private func probeLogCommand() -> String {
        sentCtrlC ? "\\r → \\x03\\x03\\r" : "\\r"
    }

    /// Insert a CommandLogEntry for the just-completed probe.
    private func appendProbeLogEntry(status: String) {
        let entry = CommandLogEntry(
            timestamp: Date(),
            command: probeLogCommand(),
            status: status,
            response: probeResponse,
            isUserTriggered: currentLogIsUserTriggered
        )
        commandLog.insert(entry, at: 0)
        if commandLog.count > Self.maxLogEntries {
            commandLog.removeLast(commandLog.count - Self.maxLogEntries)
        }
        probeResponse = ""
    }

    private func cancelPromptTimer() {
        promptTimer?.invalidate()
        promptTimer = nil
    }

    // MARK: - Chunked write

    private func writeNextChunk() {
        guard let p = peripheral, let rx = rxCharacteristic else { return }

        guard !pendingChunks.isEmpty else {
            // All chunks sent — cancel send timeout, arm response timer
            cancelSendTimeout()
            pushPhase = .awaitingResponse
            armResponseTimer(delay: Self.responseInitialTimeout)
            return
        }

        if pushPhase != .sending { pushPhase = .sending }

        let chunk = pendingChunks.removeFirst()
        chunkIndex += 1
        // Per-chunk byte-level log (hex + ASCII-with-escapes) so a stray
        // \r/\n inside a non-final chunk is visible in os_log.
        let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        let escaped = Self.escapeBytes(chunk)
        log.default("GlyWatch TX chunk %{public}d/%{public}d (%{public}d bytes) hex=%{public}@ ascii=%{public}@",
                    chunkIndex, chunkTotal, chunk.count, hex, escaped)
        // .withResponse: BLE link-layer ACKs each chunk before the next is sent,
        // pacing writes to whatever rate the watch can sustain — protects the
        // wasp-os RX buffer from overflow. Next chunk is sent from
        // peripheral(_:didWriteValueFor:error:) below.
        p.writeValue(chunk, for: rx, type: .withResponse)
    }

    /// Render bytes as ASCII with control chars/escapes visible:
    /// \r, \n, \t, \xNN for other non-printables, otherwise the literal char.
    private static func escapeBytes(_ data: Data) -> String {
        var out = ""
        for b in data {
            switch b {
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(b)))
            default: out += String(format: "\\x%02x", b)
            }
        }
        return out
    }

    // MARK: - Preview support

    #if DEBUG
    /// Lightweight preview instance — no CoreBluetooth, no DeviceDataManager required.
    static var preview: GlyWatchManager { GlyWatchManager() }

    private override init() {
        self.deviceManager = nil
        super.init()
    }
    #endif

    // MARK: - Trend mapping

    private func glyWatchTrend(from trend: GlucoseTrend?) -> String {
        switch trend {
        case .upUpUp:       return "uuu"
        case .upUp:         return "uu"
        case .up:           return "u"
        case .flat:         return "f"
        case .down:         return "d"
        case .downDown:     return "dd"
        case .downDownDown: return "ddd"
        case nil:           return "f"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension GlyWatchManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && isSending {
            connectOrScan()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        if isSending && peripheral.identifier == UserDefaults.standard.glyWatchPeripheralID {
            // Found our target while fallback-scanning for a push
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        } else if isScanning && !discoveredDevices.contains(where: { $0.id == peripheral.identifier }) {
            // UI pairing scan — show every device, no name filter
            discoveredDevices.append(DiscoveredDevice(peripheral: peripheral, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("GlyWatch connection failed: %{public}@", error?.localizedDescription ?? "unknown")
        abortSend(error: error?.localizedDescription ?? "Connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelSendTimeout()
        cancelResponseTimer()
        cancelPromptTimer()
        rxCharacteristic = nil
        self.peripheral = nil

        if isStreaming {
            isStreaming = false
            log.default("GlyWatch log stream ended")
            pushPhase = .idle
            return
        }

        let wasStillSending = isSending && !pendingChunks.isEmpty
        isSending = false
        pendingChunks = []

        if wasStillSending {
            let msg = error?.localizedDescription ?? "Disconnected mid-send"
            log.error("GlyWatch disconnected mid-send: %{public}@", msg)
            onTransmissionComplete = nil
            isDrainingReadings = false
            appendCurrentCommandLogEntry(status: msg, response: bleResponse)
            lastPushError = msg
            hasTransmitted = true
            pushPhase = .idle
        } else if !transmissionQueue.isEmpty {
            // Log the just-finished command, then start the next queued one.
            let queueStatus = lastPushError ?? (echoDetected ? "OK" : "No echo from watch")
            appendCurrentCommandLogEntry(status: queueStatus, response: bleResponse)
            let next = transmissionQueue.removeFirst()
            log.default("Sending GlyWatch queued command")
            beginTransmission(next.message, isUserTriggered: next.isUserTriggered, onComplete: next.onComplete)
        } else {
            if !echoDetected { lastPushError = "No echo from watch" }
            // Snapshot log fields BEFORE firing the completion: the completion
            // may re-enter beginTransmission (e.g. drain advancing to the next
            // reading), which overwrites currentLogCommand. We log AFTER the
            // completion runs so lastPushError reflects the completion's
            // verdict, but using the snapshotted command/response/origin.
            let completion = onTransmissionComplete
            onTransmissionComplete = nil
            hasTransmitted = true
            pushPhase = .idle
            let snapshotCmd = currentLogCommand
            let snapshotIsUser = currentLogIsUserTriggered
            let snapshotResponse = bleResponse
            currentLogCommand = nil
            completion?()
            if let cmd = snapshotCmd {
                let entry = CommandLogEntry(
                    timestamp: Date(),
                    command: cmd,
                    status: lastPushError ?? "OK",
                    response: snapshotResponse,
                    isUserTriggered: snapshotIsUser
                )
                commandLog.insert(entry, at: 0)
                if commandLog.count > Self.maxLogEntries {
                    commandLog.removeLast(commandLog.count - Self.maxLogEntries)
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GlyWatchManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.nusServiceUUID })
        else {
            log.error("GlyWatch service discovery error: %{public}@", error?.localizedDescription ?? "NUS service not found")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.nusRXCharUUID, Self.nusTXCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log.error("GlyWatch characteristic discovery error: %{public}@", error!.localizedDescription)
            central.cancelPeripheralConnection(peripheral)
            return
        }

        guard let rx = service.characteristics?.first(where: { $0.uuid == Self.nusRXCharUUID }) else {
            log.error("GlyWatch NUS RX characteristic not found")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        rxCharacteristic = rx

        // Subscribe to TX notifications — wasp-os NUS only activates its RX
        // handler once the central has enabled notifications on TX.
        if let tx = service.characteristics?.first(where: { $0.uuid == Self.nusTXCharUUID }) {
            peripheral.setNotifyValue(true, for: tx)
            // probeForPrompt() will be called from didUpdateNotificationStateFor
        } else {
            // TX not found — try writing anyway
            log.default("GlyWatch NUS TX characteristic not found, writing without subscription")
            probeForPrompt()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("GlyWatch TX notify error: %{public}@", error.localizedDescription)
        }
        if isStreaming {
            // Streaming: just listen, no probe, no payload
            log.default("GlyWatch log stream active")
            cancelSendTimeout()
            pushPhase = .streaming
        } else {
            // Normal: probe for REPL readiness before writing
            probeForPrompt()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // No-op — we now use .withResponse writes paced by didWriteValueFor.
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("GlyWatch chunk write failed: %{public}@", error.localizedDescription)
            // Continue anyway — failures here are surfaced by the send timeout / response handling
        }
        // The probe's \r and the Ctrl-C break are .withResponse writes too, so
        // their ACKs land here. Payload chunks must not start on those: the
        // first chunk is written from didUpdateValueFor once >>> is seen.
        guard !waitingForPrompt else { return }
        writeNextChunk()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }

        // While probing for REPL readiness, dispatch on the LAST prompt seen:
        //   >>>  → ready, start writing
        //   ...  → REPL is in continuation; send Ctrl-C twice and wait for >>>
        if waitingForPrompt {
            bleResponse += text
            probeResponse += text
            switch lastPromptIn(bleResponse) {
            case .ready:
                waitingForPrompt = false
                cancelPromptTimer()
                bleResponse = ""
                appendProbeLogEntry(status: sentCtrlC ? "OK after Ctrl-C" : "OK")
                log.default("GlyWatch REPL prompt detected — starting write")
                writeNextChunk()
            case .continuation:
                if !sentCtrlC { sendCtrlCBreak() }
            case .none:
                break
            }
            return
        }

        // While streaming, just accumulate — no echo/prompt logic, no timers.
        if isStreaming {
            bleResponse += text
            lastResponseDate = Date()
            return
        }

        if !responseSessionStarted {
            bleResponse = ""
            responseSessionStarted = true
        }
        receivedResponse = true
        bleResponse += text
        lastResponseDate = Date()
        log.default("GlyWatch TX: %{public}@", text)

        var justDetectedEcho = false
        if !echoDetected {
            if let echo = pendingCommandEcho, bleResponse.contains(echo) {
                echoDetected = true
                pendingCommandEcho = nil
                replPromptCount = 0
                justDetectedEcho = true
                // Count >>> only in the portion of bleResponse that follows the echo
                if let echoRange = bleResponse.range(of: echo) {
                    let afterEcho = String(bleResponse[echoRange.upperBound...])
                    replPromptCount += afterEcho.components(separatedBy: ">>>").count - 1
                }
            } else {
                // Still in preamble — keep idle timer alive but don't apply fast-disconnect yet
                armResponseTimer(delay: Self.responseIdleTimeout)
                return
            }
        }

        if !justDetectedEcho {
            replPromptCount += text.components(separatedBy: ">>>").count - 1
        }

        let delay: TimeInterval = replPromptCount >= 2 ? 0.2 : replPromptCount == 1 ? 0.5 : Self.responseIdleTimeout
        armResponseTimer(delay: delay)
    }
}

//
//  DiaWatchManager.swift
//  Loop
//

import CoreBluetooth
import Foundation
import HealthKit
import LoopKit

final class DiaWatchManager: NSObject, ObservableObject {

    // MARK: - BLE UUIDs

    static let nusServiceUUID = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let nusRXCharUUID  = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let nusTXCharUUID  = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    // MARK: - Haptic alert model

    struct HapticAlert: Codable, Equatable {
        var enabled: Bool
        var op: String      // ">" or "<"
        var thr: Int        // glucose threshold in mg/dL
        var pat: String     // pattern name

        static let allPatterns: [String] = [
            "simple_pulse", "single_buzz", "single_buzz_short", "single_buzz_long", "double_buzz", "triple_buzz", "triple_tap",
            "heartbeat", "urgent", "linear_ramp", "short_long", "long_short",
            "double_tap", "notification", "notification_single", "bounce", "rbounce", "countdown",
            "stutter", "stutter_short", "stutter_long", "sos", "fanfare", "uprising_sweep"
        ]

        static let defaults: [HapticAlert] = [
            HapticAlert(enabled: false, op: "<", thr: 90, pat: "single_buzz"),
            HapticAlert(enabled: false, op: "<", thr: 90, pat: "single_buzz"),
            HapticAlert(enabled: false, op: "<", thr: 90, pat: "single_buzz"),
            HapticAlert(enabled: false, op: "<", thr: 90, pat: "single_buzz"),
            HapticAlert(enabled: false, op: "<", thr: 90, pat: "single_buzz"),
        ]
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
            hapticAlerts: HapticAlert.defaults
        )

        init(name: String, wakeOnReading: Bool, displayBrightness: Int = 2, displayAlwaysOn: Bool = false, displaySleepSec: Int = 10, forecaster: Forecaster = .trend, od: Int = 10, nd: Int = 30, st: ButtonAndTapAction = .nothing, dt: ButtonAndTapAction = .wake, lt: ButtonAndTapAction = .nothing, sp: ButtonAndTapAction = .wake, lp: ButtonAndTapAction = .haptics, rangeCutoffs: [Int] = Preset.defaultRangeCutoffs, rangeHaptics: [String] = Preset.defaultRangeHaptics, rangePlayHaptic: [Bool] = Preset.defaultRangePlayHaptic, hapticAlerts: [HapticAlert]) {
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
            hapticAlerts = try c.decode([HapticAlert].self, forKey: .hapticAlerts)
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

    @Published var pairedDeviceName: String?
    @Published var lastPushDate: Date?
    @Published var lastPushValue: Int?
    @Published var lastPushError: String?
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var pushPhase: PushPhase = .idle
    @Published var lastResponseDate: Date?
    @Published var hasTransmitted: Bool = false
    @Published var isStreaming: Bool = false
    @Published var presets: [Preset] = UserDefaults.standard.diaWatchPresets
    @Published var bleResponse: String = ""
    @Published var pendingReadingsCount: Int = 0
    @Published var transmissionsEnabled: Bool = UserDefaults.standard.diaWatchTransmissionsEnabled {
        didSet {
            UserDefaults.standard.diaWatchTransmissionsEnabled = transmissionsEnabled
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
    private var transmissionQueue: [(message: String, onComplete: (() -> Void)?)] = []
    private var scanTimer: Timer?
    private var sendTimeoutTimer: Timer?
    private static let sendTimeout: TimeInterval = 15
    private var responseTimer: Timer?
    private static let responseInitialTimeout: TimeInterval = 20  // max wait for first byte
    private static let responseIdleTimeout: TimeInterval = 1.5    // disconnect after this much silence
    private var waitingForPrompt: Bool = false
    private var sentCtrlC: Bool = false
    private var promptTimer: Timer?
    private static let promptTimeout: TimeInterval = 5
    private var pendingCommandEcho: String?   // command text the REPL will echo back (no \r\n)
    private var echoDetected = false          // true once pendingCommandEcho seen in TX stream

    // Reading-drain state. Backfill cap of 2h prevents flooding the watch
    // after long offline periods. lastSentTs is persisted so the watermark
    // survives app restarts.
    static let maxBackfillInterval: TimeInterval = 2 * 60 * 60
    private var isDrainingReadings = false

    private weak var deviceManager: DeviceDataManager?
    private let log = DiagnosticLog(category: "DiaWatchManager")

    // MARK: - Init

    init(deviceManager: DeviceDataManager) {
        self.deviceManager = deviceManager
        self.pairedDeviceName = UserDefaults.standard.diaWatchDeviceName
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loopkit.DiaWatchManager"]
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
        let lastSent = UserDefaults.standard.diaWatchLastSentTs
        let floor = max(lastSent, cap)
        let floorDate = Date(timeIntervalSince1970: TimeInterval(floor))
        dm.glucoseStore.getGlucoseSamples(start: floorDate, end: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let samples) = result {
                    let lastSentNow = UserDefaults.standard.diaWatchLastSentTs
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
        guard transmissionsEnabled, UserDefaults.standard.diaWatchPeripheralID != nil else { return }
        drainReadings()
    }

    func pushTest(mgdl: Int = 190) {
        // Debug helper: bypasses the drain and watermark, sends a synthetic
        // reading at the current time. Watch will silently dedup if older
        // than its own last received ts.
        sendOneOffReading(mgdl: mgdl, trend: "f", ts: Int(Date().timeIntervalSince1970))
    }

    func resetReadingsWatermark() {
        UserDefaults.standard.diaWatchLastSentTs = 0
        log.default("DiaWatch readings watermark reset to 0")
        refreshPendingReadingsCount()
    }

    func drainReadings() {
        guard !isDrainingReadings else { return }
        guard let dm = deviceManager else { return }

        let now = Date()
        let cap = Int(now.addingTimeInterval(-Self.maxBackfillInterval).timeIntervalSince1970)
        let lastSent = UserDefaults.standard.diaWatchLastSentTs
        let floor = max(lastSent, cap)
        let floorDate = Date(timeIntervalSince1970: TimeInterval(floor))

        isDrainingReadings = true
        dm.glucoseStore.getGlucoseSamples(start: floorDate, end: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.log.error("DiaWatch drain query failed: %{public}@", String(describing: error))
                    self.isDrainingReadings = false
                case .success(let samples):
                    let unsent = samples.filter { Int($0.startDate.timeIntervalSince1970) > UserDefaults.standard.diaWatchLastSentTs }
                    self.pendingReadingsCount = unsent.count
                    if unsent.isEmpty {
                        self.isDrainingReadings = false
                        return
                    }
                    self.log.default("DiaWatch draining %{public}d unsent reading(s)", unsent.count)
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
        let trend = diaWatchTrend(from: deviceManager?.glucoseDisplay(for: sample)?.trendType)
        let ts = Int(sample.startDate.timeIntervalSince1970)
        let message = "GB({\"app\":\"dw\",\"t\":\"r\",\"v\":\(mgdl),\"tr\":\"\(trend)\",\"ts\":\(ts)})\r\n"
        log.default("Sending DiaWatch reading: %{public}@", message)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Unexpected watch response")
            let confirmed = self.lastPushError == nil && self.bleResponse.contains("reading received")
            if self.lastPushError == nil && !confirmed {
                self.lastPushError = "Unexpected watch response"
            }
            if confirmed {
                UserDefaults.standard.diaWatchLastSentTs = ts
                self.lastSentMgdl = mgdl
                self.lastPushDate = Date()
                self.lastPushValue = mgdl
                self.pendingReadingsCount = max(0, self.pendingReadingsCount - 1)
                self.log.default("DiaWatch push complete (ts=%{public}d)", ts)
                self.sendNextInDrain(remaining.dropFirst())
            } else {
                // Stop the drain. Next LoopDataUpdated.glucose notification
                // will re-query from the un-advanced watermark and retry
                // this sample plus anything newer.
                self.isDrainingReadings = false
                self.log.default("DiaWatch reading send failed; drain paused, will retry on next notification")
            }
        }
    }

    private func sendOneOffReading(mgdl: Int, trend: String, ts: Int) {
        let message = "GB({\"app\":\"dw\",\"t\":\"r\",\"v\":\(mgdl),\"tr\":\"\(trend)\",\"ts\":\(ts)})\r\n"
        lastSentMgdl = mgdl
        log.default("Sending DiaWatch reading (test): %{public}@", message)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.lastPushDate = Date()
            self.lastPushValue = self.lastSentMgdl
            self.evaluateResult(rejectMessage: "Unexpected watch response")
            if self.lastPushError == nil && !self.bleResponse.contains("reading received") {
                self.lastPushError = "Unexpected watch response"
            }
            self.log.default("DiaWatch test push complete")
        }
    }

    // MARK: - Preset management

    func saveRanges(at index: Int) {
        guard !isSending, index < presets.count else { return }

        let preset = presets[index]
        let rcJSON = "[" + preset.rangeCutoffs.map(String.init).joined(separator: ",") + "]"
        let rhJSON = "[" + preset.rangeHaptics.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let phJSON = "[" + preset.rangePlayHaptic.map { $0 ? "1" : "0" }.joined(separator: ",") + "]"
        let rangesMsg = "GB({\"app\":\"dw\",\"t\":\"s_r\",\"p\":\(index),\"rc\":\(rcJSON),\"rh\":\(rhJSON),\"ph\":\(phJSON)})\r\n"

        log.default("Sending DiaWatch preset %{public}d ranges", index)
        beginTransmission(rangesMsg) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected ranges")
            if self.lastPushError == nil { UserDefaults.standard.diaWatchPresets = self.presets }
            self.log.default("DiaWatch preset %{public}d ranges saved", index)
        }
    }

    func saveGeneralConfig(at index: Int) {
        guard !isSending, index < presets.count else { return }

        let preset = presets[index]
        let dsValue = preset.displayAlwaysOn ? "null" : "\(preset.displaySleepSec)"
        let fcValue = preset.forecaster == .none ? "null" : "\"\(preset.forecaster.rawValue)\""
        let configMsg = "GB({\"app\":\"dw\",\"t\":\"s_c\",\"p\":\(index),\"n\":\"\(preset.name)\",\"rw\":\(preset.wakeOnReading ? 1 : 0),\"db\":\(preset.displayBrightness),\"ds\":\(dsValue),\"fc\":\(fcValue),\"od\":\(preset.od),\"nd\":\(preset.nd),\"st\":\(preset.st.rawValue),\"dt\":\(preset.dt.rawValue),\"lt\":\(preset.lt.rawValue),\"sp\":\(preset.sp.rawValue),\"lp\":\(preset.lp.rawValue)})\r\n"

        log.default("Sending DiaWatch preset %{public}d general config", index)
        beginTransmission(configMsg) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected preset config")
            if self.lastPushError == nil { UserDefaults.standard.diaWatchPresets = self.presets }
            self.log.default("DiaWatch preset %{public}d general config saved", index)
        }
    }

    func saveAlerts(at index: Int) {
        guard !isSending, index < presets.count else { return }

        let preset = presets[index]
        var commands: [(String, (() -> Void)?)] = preset.hapticAlerts.enumerated().map { alertIdx, alert in
            let msg = alert.enabled
                ? "GB({\"app\":\"dw\",\"t\":\"s_a\",\"p\":\(index),\"idx\":\(alertIdx),\"op\":\"\(alert.op)\",\"thr\":\(alert.thr),\"pat\":\"\(alert.pat)\"})\r\n"
                : "GB({\"app\":\"dw\",\"t\":\"d_a\",\"p\":\(index),\"idx\":\(alertIdx)})\r\n"
            return (msg, nil)
        }

        commands[commands.count - 1].1 = { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected alert config")
            if self.lastPushError == nil { UserDefaults.standard.diaWatchPresets = self.presets }
            self.log.default("DiaWatch preset %{public}d alerts saved", index)
        }

        transmissionQueue = Array(commands.dropFirst())
        log.default("Sending DiaWatch preset %{public}d alerts", index)
        beginTransmission(commands[0].0, onComplete: commands[0].1)
    }

    static let maxPresets = 4

    func addPreset() {
        guard presets.count < Self.maxPresets else { return }
        let newPreset = Preset(
            name: "Preset \(presets.count)",
            wakeOnReading: false,
            hapticAlerts: HapticAlert.defaults
        )
        presets.append(newPreset)
    }

    func duplicatePreset(at index: Int) {
        guard index < presets.count, presets.count < Self.maxPresets else { return }
        var copy = presets[index]
        copy.name = "\(copy.name) copy"
        presets.append(copy)
    }

    func deleteLastPreset() {
        guard presets.count > 1, !isSending else { return }

        let lastIdx = presets.count - 1
        let isPersistedToPhone = lastIdx < UserDefaults.standard.diaWatchPresets.count

        presets.removeLast()
        UserDefaults.standard.diaWatchPresets = presets

        // If the preset was never saved to the phone, the watch doesn't know about it
        guard isPersistedToPhone else { return }

        log.default("Deleting DiaWatch preset %{public}d", lastIdx)
        beginTransmission("GB({\"app\":\"dw\",\"t\":\"d_p\",\"p\":\(lastIdx)})\r\n") { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected preset delete")
            self.log.default("DiaWatch preset %{public}d deleted", lastIdx)
        }
    }

    func activatePreset(at index: Int) {
        guard !isSending, index < presets.count else { return }
        let message = "GB({\"app\":\"dw\",\"t\":\"a_p\",\"p\":\(index)})\r\n"
        log.default("Activating DiaWatch preset %{public}d", index)
        beginTransmission(message) { [weak self] in
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

        let message = "GB({\"app\":\"dw\",\"t\":\"s_t\",\"lt\":[\(y),\(mo),\(d),\(h),\(mi),\(s)],\"ff\":\(ff)})\r\n"
        log.default("Setting DiaWatch time: lt=[%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d] ff=%{public}d",
                    y, mo, d, h, mi, s, ff)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.evaluateResult(rejectMessage: "Watch rejected set time")
            self.log.default("DiaWatch set time complete")
        }
    }

    // MARK: - Custom command

    func sendCustomCommand(_ text: String) {
        guard !isSending, !text.isEmpty else { return }
        let message = text.hasSuffix("\r\n") ? text : text + "\r\n"
        log.default("Sending DiaWatch custom command: %{public}@", text)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.lastPushError = self.receivedResponse ? nil : "No response from watch"
            self.log.default("DiaWatch custom command complete")
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
        let message = "import wasp; wasp.Haptics.\(name)()\r\n"
        log.default("Sending DiaWatch test haptic: %{public}@", name)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.lastPushError = self.receivedResponse ? nil : "No response from watch"
            self.log.default("DiaWatch test haptic complete")
        }
    }

    // MARK: - Base transmission

    private func beginTransmission(_ message: String, onComplete: (() -> Void)? = nil) {
        guard !isSending else {
            if transmissionsEnabled {
                log.default("DiaWatch enqueue (busy) [%{public}d bytes]: %{public}@", message.utf8.count, message)
                transmissionQueue.append((message: message, onComplete: onComplete))
            }
            return
        }

        guard UserDefaults.standard.diaWatchPeripheralID != nil else {
            simulateNoDevice()
            return
        }

        guard let msgData = message.data(using: .utf8) else { return }

        log.default("DiaWatch TX [%{public}d bytes]: %{public}@", message.utf8.count, message)

        pendingCommandEcho = message.trimmingCharacters(in: .whitespacesAndNewlines)
        echoDetected = false
        pendingChunks = stride(from: 0, to: msgData.count, by: 20).map {
            Data(msgData[$0 ..< min($0 + 20, msgData.count)])
        }
        for (i, chunk) in pendingChunks.enumerated() {
            let asString = String(data: chunk, encoding: .utf8) ?? chunk.map { String(format: "%02x", $0) }.joined()
            log.default("DiaWatch TX chunk %{public}d/%{public}d (%{public}d bytes): %{public}@",
                        i + 1, pendingChunks.count, chunk.count, asString)
        }

        isSending = true
        onTransmissionComplete = onComplete
        receivedResponse = false
        responseSessionStarted = false
        replPromptCount = 0
        pushPhase = .connecting
        startSendTimeout()
        connectOrScan()
    }

    private func simulateNoDevice() {
        isSending = true
        pushPhase = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lastPushError = "No device paired"
            self.isSending = false
            self.hasTransmitted = true
            self.pushPhase = .idle
        }
    }

    private func startSendTimeout() {
        sendTimeoutTimer?.invalidate()
        sendTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.sendTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isSending else { return }
            self.log.error("DiaWatch send timed out after %{public}g s", Self.sendTimeout)
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
            self.log.default("DiaWatch response timer fired — disconnecting")
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
        lastPushError = error
        hasTransmitted = true
        pushPhase = .idle
    }

    private func connectOrScan() {
        guard central.state == .poweredOn else { return }

        if let id = UserDefaults.standard.diaWatchPeripheralID,
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
        UserDefaults.standard.diaWatchPeripheralID = device.peripheral.identifier
        UserDefaults.standard.diaWatchDeviceName = device.peripheral.name
        pairedDeviceName = device.peripheral.name
        log.default("Paired DiaWatch device: %{public}@ (%{public}@)", device.name, device.peripheral.identifier.uuidString)
    }

    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rxCharacteristic = nil
        isSending = false
        pendingChunks = []
        onTransmissionComplete = nil
        UserDefaults.standard.diaWatchPeripheralID = nil
        UserDefaults.standard.diaWatchDeviceName = nil
        pairedDeviceName = nil
        lastPushDate = nil
        lastPushValue = nil
        lastPushError = nil
        bleResponse = ""
        log.default("Forgot DiaWatch device")
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

        // Send a bare \r to solicit a prompt. If the REPL is at >>>, we
        // proceed. If it answers with ... (continuation prompt — stuck in
        // a multi-line input), we send Ctrl-C twice + \r to break out and
        // wait for >>>. If the watch is booting, no prompt arrives and we
        // time out safely instead of interrupting the boot sequence.
        log.default("DiaWatch probing for REPL prompt (sending \\r)")
        p.writeValue(Data([0x0D]), for: rx, type: .withResponse)

        startPromptTimer()
    }

    private func sendCtrlCBreak() {
        guard let p = peripheral, let rx = rxCharacteristic else { return }
        log.default("DiaWatch continuation prompt detected — sending \\x03\\x03 + \\r")
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
                self.log.default("DiaWatch REPL prompt not received within %{public}.0f s", Self.promptTimeout)
                self.abortSend(error: "REPL not ready")
            }
        }
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
        // .withResponse: BLE link-layer ACKs each chunk before the next is sent,
        // pacing writes to whatever rate the watch can sustain — protects the
        // wasp-os RX buffer from overflow. Next chunk is sent from
        // peripheral(_:didWriteValueFor:error:) below.
        p.writeValue(chunk, for: rx, type: .withResponse)
    }

    // MARK: - Preview support

    #if DEBUG
    /// Lightweight preview instance — no CoreBluetooth, no DeviceDataManager required.
    static var preview: DiaWatchManager { DiaWatchManager() }

    private override init() {
        self.deviceManager = nil
        super.init()
    }
    #endif

    // MARK: - Trend mapping

    private func diaWatchTrend(from trend: GlucoseTrend?) -> String {
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

extension DiaWatchManager: CBCentralManagerDelegate {

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
        if isSending && peripheral.identifier == UserDefaults.standard.diaWatchPeripheralID {
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
        log.error("DiaWatch connection failed: %{public}@", error?.localizedDescription ?? "unknown")
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
            log.default("DiaWatch log stream ended")
            pushPhase = .idle
            return
        }

        let wasStillSending = isSending && !pendingChunks.isEmpty
        isSending = false
        pendingChunks = []

        if wasStillSending {
            let msg = error?.localizedDescription ?? "Disconnected mid-send"
            log.error("DiaWatch disconnected mid-send: %{public}@", msg)
            onTransmissionComplete = nil
            isDrainingReadings = false
            lastPushError = msg
            hasTransmitted = true
            pushPhase = .idle
        } else if !transmissionQueue.isEmpty {
            let next = transmissionQueue.removeFirst()
            log.default("Sending DiaWatch queued command")
            beginTransmission(next.message, onComplete: next.onComplete)
        } else {
            if !echoDetected { lastPushError = "No echo from watch" }
            // Capture-and-clear BEFORE firing: the completion may re-enter
            // beginTransmission (e.g. drain advancing to the next reading),
            // which sets a fresh onTransmissionComplete and pushPhase. If we
            // cleared them after firing, we'd clobber the new closure and
            // wedge the drain — silently, since the new completion never
            // gets called and isDrainingReadings stays true.
            let completion = onTransmissionComplete
            onTransmissionComplete = nil
            hasTransmitted = true
            pushPhase = .idle
            completion?()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DiaWatchManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.nusServiceUUID })
        else {
            log.error("DiaWatch service discovery error: %{public}@", error?.localizedDescription ?? "NUS service not found")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.nusRXCharUUID, Self.nusTXCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log.error("DiaWatch characteristic discovery error: %{public}@", error!.localizedDescription)
            central.cancelPeripheralConnection(peripheral)
            return
        }

        guard let rx = service.characteristics?.first(where: { $0.uuid == Self.nusRXCharUUID }) else {
            log.error("DiaWatch NUS RX characteristic not found")
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
            log.default("DiaWatch NUS TX characteristic not found, writing without subscription")
            probeForPrompt()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("DiaWatch TX notify error: %{public}@", error.localizedDescription)
        }
        if isStreaming {
            // Streaming: just listen, no probe, no payload
            log.default("DiaWatch log stream active")
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
            log.error("DiaWatch chunk write failed: %{public}@", error.localizedDescription)
            // Continue anyway — failures here are surfaced by the send timeout / response handling
        }
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
            switch lastPromptIn(bleResponse) {
            case .ready:
                waitingForPrompt = false
                cancelPromptTimer()
                bleResponse = ""
                log.default("DiaWatch REPL prompt detected — starting write")
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
        log.default("DiaWatch TX: %{public}@", text)

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

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

    // MARK: - Haptic slot model

    struct HapticSlot: Codable, Equatable {
        var enabled: Bool
        var op: String      // ">" or "<"
        var thr: Int        // glucose threshold in mg/dL
        var pat: String     // pattern name

        static let allPatterns: [String] = [
            "simple_pulse", "notification_single", "single_buzz", "triple_tap",
            "heartbeat", "urgent", "linear_ramp", "short_long", "long_short",
            "double_tap", "notification", "bounce", "rbounce", "countdown",
            "stutter", "sos", "fanfare", "uprising_sweep"
        ]

        static let defaults: [HapticSlot] = (0..<5).map { _ in
            HapticSlot(enabled: false, op: ">", thr: 180, pat: "single_buzz")
        }
    }

    // MARK: - Preset model

    struct Preset: Codable, Equatable {
        var name: String
        var hapOnReading: Bool
        var wakeOnReading: Bool
        var hapticSlots: [HapticSlot]

        static let defaultPreset = Preset(
            name: "default",
            hapOnReading: false,
            wakeOnReading: false,
            hapticSlots: HapticSlot.defaults
        )
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
        case success
    }

    @Published var pairedDeviceName: String?
    @Published var lastPushDate: Date?
    @Published var lastPushValue: Int?
    @Published var lastPushError: String?
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var pushPhase: PushPhase = .idle
    @Published var presets: [Preset] = UserDefaults.standard.diaWatchPresets
    @Published var bleResponse: String = ""

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
    private var pendingCommandEcho: String?   // command text the REPL will echo back (no \r\n)
    private var echoDetected = false          // true once pendingCommandEcho seen in TX stream

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
        push()
    }

    // MARK: - Push (glucose reading)

    func push() {
        guard !isSending, UserDefaults.standard.diaWatchPeripheralID != nil else { return }
        guard let dm = deviceManager, let sample = dm.glucoseStore.latestGlucose else { return }

        let mgdl = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
        let trend = diaWatchTrend(from: dm.glucoseDisplay(for: sample)?.trendType)
        let ts = Int(sample.startDate.timeIntervalSince1970)
        sendReading(mgdl: mgdl, trend: trend, ts: ts)
    }

    func pushTest(mgdl: Int = 190) {
        sendReading(mgdl: mgdl, trend: " -", ts: Int(Date().timeIntervalSince1970))
    }

    private func sendReading(mgdl: Int, trend: String, ts: Int) {
        let message = "GB({\"face\":\"diawatch\",\"t\":\"reading\",\"v\":\(mgdl),\"trend\":\"\(trend)\",\"ts\":\(ts)})\r\n"
        lastSentMgdl = mgdl
        log.default("Sending DiaWatch reading: %{public}@", message)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            self.lastPushDate = Date()
            self.lastPushValue = self.lastSentMgdl
            if self.receivedResponse {
                self.lastPushError = self.bleResponse.contains("reading received")
                    ? nil
                    : "Unexpected watch response"
            } else {
                self.lastPushError = "No response from watch"
            }
            self.log.default("DiaWatch push complete")
        }
    }

    // MARK: - Preset management

    func savePreset(at index: Int) {
        guard !isSending, index < presets.count else { return }

        UserDefaults.standard.diaWatchPresets = presets

        let preset = presets[index]
        let configMsg = "GB({\"face\":\"diawatch\",\"t\":\"s_c\",\"p\":\(index),\"n\":\"\(preset.name)\",\"hap\":\(preset.hapOnReading ? 1 : 0),\"wake\":\(preset.wakeOnReading ? 1 : 0)})\r\n"

        var commands: [(String, (() -> Void)?)] = [(configMsg, nil)]
        commands += preset.hapticSlots.enumerated().map { slotIdx, slot -> (String, (() -> Void)?) in
            let msg = slot.enabled
                ? "GB({\"face\":\"diawatch\",\"t\":\"s_h\",\"p\":\(index),\"idx\":\(slotIdx),\"op\":\"\(slot.op)\",\"thr\":\(slot.thr),\"pat\":\"\(slot.pat)\"})\r\n"
                : "GB({\"face\":\"diawatch\",\"t\":\"d_h\",\"p\":\(index),\"idx\":\(slotIdx)})\r\n"
            return (msg, nil)
        }

        commands[commands.count - 1].1 = { [weak self] in
            guard let self else { return }
            if self.receivedResponse {
                self.lastPushError = self.bleResponse.contains("ERROR") ? "Watch rejected preset config" : nil
            } else {
                self.lastPushError = "No response from watch"
            }
            self.log.default("DiaWatch preset %{public}d saved", index)
        }

        transmissionQueue = Array(commands.dropFirst())
        log.default("Sending DiaWatch preset %{public}d config", index)
        beginTransmission(commands[0].0, onComplete: commands[0].1)
    }

    func addPreset() {
        let newPreset = Preset(
            name: "preset \(presets.count)",
            hapOnReading: false,
            wakeOnReading: false,
            hapticSlots: HapticSlot.defaults
        )
        presets.append(newPreset)
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
        beginTransmission("GB({\"face\":\"diawatch\",\"t\":\"d_p\",\"p\":\(lastIdx)})\r\n") { [weak self] in
            guard let self else { return }
            if self.receivedResponse {
                self.lastPushError = self.bleResponse.contains("ERROR") ? "Watch rejected preset delete" : nil
            } else {
                self.lastPushError = "No response from watch"
            }
            self.log.default("DiaWatch preset %{public}d deleted", lastIdx)
        }
    }

    func activatePreset(at index: Int) {
        guard !isSending, index < presets.count else { return }
        let message = "GB({\"face\":\"diawatch\",\"t\":\"a_p\",\"p\":\(index)})\r\n"
        log.default("Activating DiaWatch preset %{public}d", index)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            if self.receivedResponse {
                self.lastPushError = self.bleResponse.contains("ERROR") ? "Watch rejected preset activation" : nil
            } else {
                self.lastPushError = "No response from watch"
            }
        }
    }

    // MARK: - Custom command

    func sendCustomCommand(_ text: String) {
        guard !isSending, !text.isEmpty else { return }
        let message = text.hasSuffix("\r\n") ? text : text + "\r\n"
        log.default("Sending DiaWatch custom command: %{public}@", text)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            if !self.receivedResponse {
                self.lastPushError = "No response from watch"
            }
            self.log.default("DiaWatch custom command complete")
        }
    }

    // MARK: - Haptic test

    func testHaptic(name: String) {
        guard !isSending else { return }
        let message = "import wasp; wasp.Haptics.\(name)()\r\n"
        log.default("Sending DiaWatch test haptic: %{public}@", name)
        beginTransmission(message) { [weak self] in
            guard let self else { return }
            if !self.receivedResponse {
                self.lastPushError = "No response from watch"
            }
            self.log.default("DiaWatch test haptic complete")
        }
    }

    // MARK: - Base transmission

    private func beginTransmission(_ message: String, onComplete: (() -> Void)? = nil) {
        guard !isSending else { return }

        guard UserDefaults.standard.diaWatchPeripheralID != nil else {
            simulateNoDevice()
            return
        }

        guard let msgData = message.data(using: .utf8) else { return }

        // Prepend \x03\x03 (double Ctrl+C) to clear any stuck REPL state.
        // Store the clean command text so we can detect its echo in the TX stream.
        pendingCommandEcho = message.trimmingCharacters(in: .whitespacesAndNewlines)
        echoDetected = false
        let data = Data([0x03, 0x03]) + msgData
        pendingChunks = stride(from: 0, to: data.count, by: 20).map {
            Data(data[$0 ..< min($0 + 20, data.count)])
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
            self.pushPhase = .idle
        }
    }

    private func startSendTimeout() {
        sendTimeoutTimer?.invalidate()
        sendTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.sendTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isSending else { return }
            self.log.error("DiaWatch send timed out after %{public}g s", Self.sendTimeout)
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
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
        isSending = false
        pendingChunks = []
        peripheral = nil
        rxCharacteristic = nil
        onTransmissionComplete = nil
        transmissionQueue = []
        pendingCommandEcho = nil
        echoDetected = false
        lastPushError = error
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

    // MARK: - Chunked write

    private func writeNextChunk() {
        guard let p = peripheral, let rx = rxCharacteristic else { return }

        guard !pendingChunks.isEmpty else {
            // All chunks sent — cancel send timeout, arm response timer
            cancelSendTimeout()
            pushPhase = .success
            armResponseTimer(delay: Self.responseInitialTimeout)
            return
        }

        if pushPhase != .sending { pushPhase = .sending }

        guard p.canSendWriteWithoutResponse else {
            // Flow-control: peripheralIsReady(toSendWriteWithoutResponse:) will resume us
            return
        }

        let chunk = pendingChunks.removeFirst()
        p.writeValue(chunk, for: rx, type: .withoutResponse)
        writeNextChunk()
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
        case .upUpUp:       return ">>"
        case .upUp:         return ">>"
        case .up:           return "> "
        case .flat:         return " -"
        case .down:         return "< "
        case .downDown:     return "<<"
        case .downDownDown: return "<<"
        case nil:           return " -"
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
        rxCharacteristic = nil
        self.peripheral = nil
        let wasStillSending = isSending && !pendingChunks.isEmpty
        isSending = false
        pendingChunks = []

        if wasStillSending {
            let msg = error?.localizedDescription ?? "Disconnected mid-send"
            log.error("DiaWatch disconnected mid-send: %{public}@", msg)
            onTransmissionComplete = nil
            lastPushError = msg
            pushPhase = .idle
        } else if !transmissionQueue.isEmpty {
            let next = transmissionQueue.removeFirst()
            log.default("Sending DiaWatch queued command")
            beginTransmission(next.message, onComplete: next.onComplete)
        } else {
            onTransmissionComplete?()
            onTransmissionComplete = nil
            if !echoDetected {
                lastPushError = "No echo from watch"
            }
            pushPhase = .idle
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
            // writeNextChunk() will be called from didUpdateNotificationStateFor
        } else {
            // TX not found — try writing anyway
            log.default("DiaWatch NUS TX characteristic not found, writing without subscription")
            writeNextChunk()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("DiaWatch TX notify error: %{public}@", error.localizedDescription)
        }
        // TX subscription done (or failed) — start writing to RX regardless
        writeNextChunk()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeNextChunk()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        if !responseSessionStarted {
            bleResponse = ""
            responseSessionStarted = true
        }
        receivedResponse = true
        bleResponse += text
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

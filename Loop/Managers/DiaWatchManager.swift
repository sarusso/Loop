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

    // MARK: - Published state (drives settings UI)

    struct DiscoveredDevice: Identifiable {
        let peripheral: CBPeripheral
        let rssi: Int          // dBm, e.g. -55
        var id: UUID { peripheral.identifier }
        var name: String { peripheral.name ?? "Unknown" }
    }

    @Published var pairedDeviceName: String?
    @Published var lastPushDate: Date?
    @Published var lastPushError: String?
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [DiscoveredDevice] = []

    // MARK: - Private state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var isSending = false
    private var scanTimer: Timer?
    private var sendTimeoutTimer: Timer?
    private static let sendTimeout: TimeInterval = 15

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

    // MARK: - Push

    func push() {
        guard !isSending, UserDefaults.standard.diaWatchPeripheralID != nil else { return }
        guard let dm = deviceManager, let sample = dm.glucoseStore.latestGlucose else { return }

        let mgdl = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
        let trend = diaWatchTrend(from: dm.glucoseDisplay(for: sample)?.trendType)
        let ts = Int(sample.startDate.timeIntervalSince1970)
        send(mgdl: mgdl, trend: trend, ts: ts)
    }

    func pushTest() {
        send(mgdl: 190, trend: " -", ts: Int(Date().timeIntervalSince1970))
    }

    private func send(mgdl: Int, trend: String, ts: Int) {
        guard !isSending, UserDefaults.standard.diaWatchPeripheralID != nil else { return }

        let message = "GB({\"face\": \"diawatch\", \"t\": \"reading\", \"v\": \(mgdl), \"trend\": \"\(trend)\", \"ts\": \(ts)})\r\n"
        guard let data = message.data(using: .utf8) else { return }

        pendingChunks = stride(from: 0, to: data.count, by: 20).map {
            Data(data[$0 ..< min($0 + 20, data.count)])
        }

        isSending = true
        log.default("Sending DiaWatch reading: %{public}@", message)
        startSendTimeout()
        connectOrScan()
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

    private func abortSend(error: String) {
        cancelSendTimeout()
        isSending = false
        pendingChunks = []
        peripheral = nil
        rxCharacteristic = nil
        lastPushError = error
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
        UserDefaults.standard.diaWatchPeripheralID = nil
        UserDefaults.standard.diaWatchDeviceName = nil
        pairedDeviceName = nil
        lastPushDate = nil
        lastPushError = nil
        log.default("Forgot DiaWatch device")
    }

    // MARK: - Chunked write

    private func writeNextChunk() {
        guard let p = peripheral, let rx = rxCharacteristic else { return }

        guard !pendingChunks.isEmpty else {
            // All chunks sent — cancel timeout, wait 2 s then disconnect cleanly
            cancelSendTimeout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let p = self.peripheral else { return }
                self.central.cancelPeripheralConnection(p)
            }
            return
        }

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
        rxCharacteristic = nil
        self.peripheral = nil
        let wasStillSending = isSending && !pendingChunks.isEmpty
        isSending = false
        pendingChunks = []

        if wasStillSending {
            let msg = error?.localizedDescription ?? "Disconnected mid-send"
            log.error("DiaWatch disconnected mid-send: %{public}@", msg)
            lastPushError = msg
        } else {
            log.default("DiaWatch push complete")
            lastPushDate = Date()
            lastPushError = nil
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
}

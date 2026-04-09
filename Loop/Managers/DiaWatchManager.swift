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

    // MARK: - Published state (drives settings UI)

    @Published var pairedDeviceName: String?
    @Published var lastPushDate: Date?
    @Published var lastPushError: String?
    @Published var isScanning: Bool = false
    @Published var discoveredDevices: [CBPeripheral] = []

    // MARK: - Private state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var isSending = false
    private var scanTimer: Timer?

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
        let message = "GB({\"face\": \"diawatch\", \"t\": \"reading\", \"v\": \(mgdl), \"trend\": \"\(trend)\", \"ts\": \(ts)})\r\n"

        guard let data = message.data(using: .utf8) else { return }

        pendingChunks = stride(from: 0, to: data.count, by: 20).map {
            Data(data[$0 ..< min($0 + 20, data.count)])
        }

        isSending = true
        log.default("Sending DiaWatch reading: %{public}@", message)
        connectOrScan()
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
        central.scanForPeripherals(withServices: [Self.nusServiceUUID], options: nil)
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

    func pair(_ p: CBPeripheral) {
        stopScan()
        UserDefaults.standard.diaWatchPeripheralID = p.identifier
        UserDefaults.standard.diaWatchDeviceName = p.name
        pairedDeviceName = p.name
        log.default("Paired DiaWatch device: %{public}@ (%{public}@)", p.name ?? "unknown", p.identifier.uuidString)
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
            // All chunks sent — wait 2 s then disconnect cleanly
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
        let name = peripheral.name ?? ""
        guard name.localizedCaseInsensitiveContains("pinetime") ||
              name.localizedCaseInsensitiveContains("diawatch")
        else { return }

        if isSending && peripheral.identifier == UserDefaults.standard.diaWatchPeripheralID {
            // Found our target while fallback-scanning for a push
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        } else if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("DiaWatch connection failed: %{public}@", error?.localizedDescription ?? "unknown")
        isSending = false
        pendingChunks = []
        lastPushError = error?.localizedDescription ?? "Connection failed"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rxCharacteristic = nil
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
        peripheral.discoverCharacteristics([Self.nusRXCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let rx = service.characteristics?.first(where: { $0.uuid == Self.nusRXCharUUID })
        else {
            log.error("DiaWatch characteristic discovery error: %{public}@", error?.localizedDescription ?? "NUS RX not found")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        rxCharacteristic = rx
        writeNextChunk()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeNextChunk()
    }
}

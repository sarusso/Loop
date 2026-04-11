//
//  DiaWatchSettingsView.swift
//  Loop
//

import CoreBluetooth
import SwiftUI

struct DiaWatchSettingsView: View {

    @ObservedObject var manager: DiaWatchManager

    @State private var gearRotation: Double = 0
    @State private var testMgdl: Int = 190
    @State private var hapticsDirty = false
    @State private var configDirty = false

    private enum ActiveButton { case none, test, haptics, config }
    @State private var activeButton: ActiveButton = .none

    struct ButtonStatus {
        var text: String
        var isError: Bool
    }
    @State private var hapticStatus: ButtonStatus? = nil
    @State private var configStatus: ButtonStatus? = nil
    @State private var testStatus: ButtonStatus? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private static func formatPattern(_ pat: String) -> String {
        pat.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    var body: some View {
        Form {
            statusSection
            hapticsSection
            preferencesSection
            debugSection
        }
        .navigationBarTitle("DiaWatch", displayMode: .inline)
        .onChange(of: manager.hapticSlots) { _ in hapticsDirty = true }
        .onChange(of: manager.hapOnReading) { _ in configDirty = true }
        .onChange(of: manager.wakeOnReading) { _ in configDirty = true }
        .onChange(of: manager.pushPhase) { phase in
            guard phase == .idle else { return }

            let isError = manager.lastPushError != nil
            let which = activeButton
            activeButton = .none

            let text: String
            switch which {
            case .test:    text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .haptics: text = isError ? (manager.lastPushError ?? "Failed") : "Saved!"
            case .config:  text = isError ? (manager.lastPushError ?? "Failed") : "Saved!"
            case .none:    return
            }

            let status = ButtonStatus(text: text, isError: isError)
            switch which {
            case .test:
                testStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testStatus = nil }
            case .haptics:
                hapticStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { hapticStatus = nil }
            case .config:
                configStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { configStatus = nil }
            case .none: break
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section(header: Text("Status")) {
            if let name = manager.pairedDeviceName {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text("Paired").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Forget") { manager.forget() }
                        .foregroundColor(.red)
                }
            } else {
                Text("No device paired").foregroundColor(.secondary)
            }

            if manager.isScanning {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .rotationEffect(.degrees(gearRotation))
                        .onAppear {
                            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                gearRotation = 360
                            }
                        }
                        .onDisappear { gearRotation = 0 }
                        .foregroundColor(.accentColor)
                    Text("Scanning…").padding(.leading, 4).foregroundColor(.secondary)
                    Spacer()
                    Button("Stop") { manager.stopScan() }
                }
                if manager.discoveredDevices.isEmpty {
                    Text("Looking for nearby BLE devices…")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(manager.discoveredDevices.sorted(by: { $0.rssi > $1.rssi })) { device in
                        Button(action: { manager.pair(device) }) {
                            HStack {
                                Text(device.name).foregroundColor(.primary)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundColor(rssiColor(device.rssi))
                                Text("Pair").foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } else {
                Button(manager.pairedDeviceName != nil ? "Scan for different device" : "Scan for device") {
                    manager.startScan()
                }
            }

            if let date = manager.lastPushDate {
                HStack {
                    Text("Last push")
                    Spacer()
                    if let value = manager.lastPushValue {
                        Text("\(value) mg/dL at \(Self.timeFormatter.string(from: date))")
                            .foregroundColor(.secondary)
                    } else {
                        Text(Self.timeFormatter.string(from: date))
                            .foregroundColor(.secondary)
                    }
                }
            } else if manager.pairedDeviceName != nil {
                Text("No readings sent yet").foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Haptics

    private var hapticsSection: some View {
        Section(
            header: Text("Haptics"),
            footer: Text("The watch evaluates these conditions on each incoming glucose reading and fires the selected pattern.")
        ) {
            ForEach(manager.hapticSlots.indices, id: \.self) { idx in
                hapticSlotRow(idx: idx)
            }
            actionRow(
                label: "Save",
                id: .haptics,
                dirty: hapticsDirty,
                status: hapticStatus
            ) {
                activeButton = .haptics
                manager.applyHapticSlots()
                hapticsDirty = false
            }
        }
    }

    @ViewBuilder
    private func hapticSlotRow(idx: Int) -> some View {
        let slot = manager.hapticSlots[idx]
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Slot \(idx + 1)", isOn: Binding(
                get: { manager.hapticSlots[idx].enabled },
                set: { manager.hapticSlots[idx].enabled = $0 }
            ))
            if slot.enabled {
                HStack(spacing: 12) {
                    Picker("", selection: Binding(
                        get: { manager.hapticSlots[idx].op },
                        set: { manager.hapticSlots[idx].op = $0 }
                    )) {
                        Text("Above").tag(">")
                        Text("Below").tag("<")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 130)

                    Stepper(
                        "\(manager.hapticSlots[idx].thr) mg/dL",
                        value: Binding(
                            get: { manager.hapticSlots[idx].thr },
                            set: { manager.hapticSlots[idx].thr = $0 }
                        ),
                        in: 40...400,
                        step: 10
                    )
                }

                Picker("Pattern", selection: Binding(
                    get: { manager.hapticSlots[idx].pat },
                    set: { manager.hapticSlots[idx].pat = $0 }
                )) {
                    ForEach(DiaWatchManager.HapticSlot.allPatterns, id: \.self) { pat in
                        Text(Self.formatPattern(pat)).tag(pat)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section(header: Text("Preferences")) {
            Toggle("Haptic on every reading", isOn: $manager.hapOnReading)
            Toggle("Wake screen on new reading", isOn: $manager.wakeOnReading)
            actionRow(
                label: "Save",
                id: .config,
                dirty: configDirty,
                status: configStatus
            ) {
                activeButton = .config
                manager.sendConfig()
                configDirty = false
            }
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        Section(header: Text("Debug")) {
            Stepper(value: $testMgdl, in: 40...400, step: 5) {
                Text("Test value: \(testMgdl) mg/dL")
            }
            actionRow(
                label: "Send test reading",
                id: .test,
                dirty: false,
                status: testStatus
            ) {
                activeButton = .test
                manager.pushTest(mgdl: testMgdl)
            }
        }
    }

    // MARK: - Shared action row

    private func actionRow(
        label: String,
        id: ActiveButton,
        dirty: Bool,
        status: ButtonStatus?,
        action: @escaping () -> Void
    ) -> some View {
        let isSending = manager.pushPhase != .idle
        let isActive = activeButton == id

        return HStack {
            Button(action: action) {
                Text(label)
                    .foregroundColor(isSending ? .secondary : (dirty ? .orange : .accentColor))
            }
            .disabled(isSending)

            Spacer()

            if isActive && isSending {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.75)
                    Text("Sending…").font(.caption).foregroundColor(.secondary)
                }
            } else if let s = status {
                HStack(spacing: 4) {
                    Image(systemName: s.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(s.isError ? .orange : .green)
                    Text(s.text).font(.caption).foregroundColor(s.isError ? .orange : .green)
                }
            } else if dirty {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Helpers

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case (-60)...: return .green
        case (-80)...: return .yellow
        default:       return .red
        }
    }
}

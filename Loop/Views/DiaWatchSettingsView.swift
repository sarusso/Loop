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
            deviceSection
            statusSection
            hapticsSection
            preferencesSection
        }
        .navigationBarTitle("DiaWatch", displayMode: .inline)
        .onChange(of: manager.hapticSlots) { _ in hapticsDirty = true }
        .onChange(of: manager.hapOnReading) { _ in configDirty = true }
        .onChange(of: manager.wakeOnReading) { _ in configDirty = true }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section(header: Text("Paired Device")) {
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
        }
    }

    private var statusSection: some View {
        Section(header: Text("Status")) {
            pushPhaseRow
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
            }
            if let error = manager.lastPushError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).font(.caption)
                }
            }
            if manager.lastPushDate == nil && manager.lastPushError == nil && manager.pushPhase == .idle {
                Text("No readings sent yet").foregroundColor(.secondary)
            }

            if manager.pairedDeviceName != nil {
                Stepper(value: $testMgdl, in: 40...400, step: 5) {
                    Text("Test: \(testMgdl) mg/dL")
                }
                Button("Send test reading") {
                    manager.pushTest(mgdl: testMgdl)
                }
                .disabled(manager.pushPhase != .idle)
            }
        }
    }

    private var hapticsSection: some View {
        Section(
            header: Text("Haptics"),
            footer: Text("The watch evaluates these conditions on each incoming glucose reading and fires the selected pattern.")
        ) {
            ForEach(manager.hapticSlots.indices, id: \.self) { idx in
                hapticSlotRow(idx: idx)
            }
            applyButton(dirty: hapticsDirty) {
                manager.applyHapticSlots()
                hapticsDirty = false
            }
            .disabled(manager.pairedDeviceName == nil || manager.pushPhase != .idle)
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

    private var preferencesSection: some View {
        Section(header: Text("Preferences")) {
            Toggle("Haptic on every reading", isOn: $manager.hapOnReading)
            Toggle("Wake screen on new reading", isOn: $manager.wakeOnReading)
            applyButton(dirty: configDirty) {
                manager.sendConfig()
                configDirty = false
            }
            .disabled(manager.pairedDeviceName == nil || manager.pushPhase != .idle)
        }
    }

    // MARK: - Shared apply button

    private func applyButton(dirty: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Apply to watch")
                if dirty {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
            .foregroundColor(dirty ? .orange : .accentColor)
        }
    }

    // MARK: - Push phase row

    @ViewBuilder
    private var pushPhaseRow: some View {
        switch manager.pushPhase {
        case .idle:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.accentColor)
                Text("Connecting…").foregroundColor(.secondary)
            }
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Sending…").foregroundColor(.secondary)
            }
        case .success:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Sent!").foregroundColor(.green)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Helpers

    /// Green > -60, yellow -60…-80, red < -80
    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case (-60)...: return .green
        case (-80)...: return .yellow
        default:       return .red
        }
    }
}

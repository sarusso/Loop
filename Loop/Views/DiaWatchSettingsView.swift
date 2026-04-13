//
//  DiaWatchSettingsView.swift
//  Loop
//

import CoreBluetooth
import SwiftUI

struct DiaWatchSettingsView: View {

    @ObservedObject var manager: DiaWatchManager
    @Environment(\.dismiss) private var dismiss

    @State private var gearRotation: Double = 0
    @State private var testMgdl: Int = 190
    @State private var selectedPresetIndex: Int = 0
    @State private var presetDirty = false

    private enum ActiveButton { case none, test, savePreset, activatePreset, deletePreset, testHaptic, customCommand, setTime, battery, freeMem, uptime }
    @State private var activeButton: ActiveButton = .none

    struct ButtonStatus {
        var text: String
        var isError: Bool
    }
    @State private var savePresetStatus: ButtonStatus? = nil
    @State private var activatePresetStatus: ButtonStatus? = nil
    @State private var deletePresetStatus: ButtonStatus? = nil
    @State private var showUnsavedChangesAlert = false
    @State private var pendingPresetSwitch: Int = 0
    @State private var pendingDismiss = false
    @State private var pendingAddPreset = false
    @State private var testStatus: ButtonStatus? = nil
    @State private var testHapticStatus: ButtonStatus? = nil
    @State private var selectedHapticPattern: String = DiaWatchManager.HapticSlot.allPatterns[0]
    @State private var customCommandStatus: ButtonStatus? = nil
    @State private var customCommandText: String = ""
    @State private var setTimeStatus: ButtonStatus? = nil
    @State private var batteryStatus: ButtonStatus? = nil
    @State private var freeMemStatus: ButtonStatus? = nil
    @State private var uptimeStatus: ButtonStatus? = nil

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
            configurationSection
            testHapticsSection
            debugSection
        }
        .navigationBarTitle("DiaWatch", displayMode: .inline)
        .navigationBarBackButtonHidden(presetDirty)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if presetDirty {
                    Button {
                        pendingDismiss = true
                        showUnsavedChangesAlert = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            Text("Settings")
                        }
                    }
                }
            }
        }
        .onChange(of: manager.presets) { _ in presetDirty = true }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Discard", role: .destructive) {
                let savedPresets = UserDefaults.standard.diaWatchPresets
                if selectedPresetIndex < savedPresets.count {
                    manager.presets[selectedPresetIndex] = savedPresets[selectedPresetIndex]
                } else {
                    manager.presets.removeLast()
                }
                presetDirty = false
                if pendingDismiss {
                    pendingDismiss = false
                    dismiss()
                } else if pendingAddPreset {
                    pendingAddPreset = false
                    manager.addPreset()
                    selectedPresetIndex = manager.presets.count - 1
                    presetDirty = true
                } else {
                    selectedPresetIndex = min(pendingPresetSwitch, manager.presets.count - 1)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDismiss = false
                pendingAddPreset = false
            }
        } message: {
            Text("The mode \"\(manager.presets[selectedPresetIndex].name)\" has unsaved changes. Discard them?")
        }
        .onChange(of: manager.pushPhase) { phase in
            guard phase == .idle else { return }

            let isError = manager.lastPushError != nil
            let which = activeButton
            activeButton = .none

            let text: String
            switch which {
            case .test:          text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .savePreset:    text = isError ? (manager.lastPushError ?? "Failed") : "Saved!"
            case .activatePreset: text = isError ? (manager.lastPushError ?? "Failed") : "Activated!"
            case .deletePreset:   text = isError ? (manager.lastPushError ?? "Failed") : "Deleted!"
            case .testHaptic:    text = isError ? (manager.lastPushError ?? "Failed") : "Played!"
            case .customCommand: text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .setTime:       text = isError ? (manager.lastPushError ?? "Failed") : "Set!"
            case .battery:       text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .freeMem:       text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .uptime:        text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .none:          return
            }

            let status = ButtonStatus(text: text, isError: isError)
            switch which {
            case .test:
                testStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testStatus = nil }
            case .savePreset:
                savePresetStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { savePresetStatus = nil }
            case .activatePreset:
                activatePresetStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { activatePresetStatus = nil }
            case .deletePreset:
                deletePresetStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { deletePresetStatus = nil }
            case .testHaptic:
                testHapticStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testHapticStatus = nil }
            case .customCommand:
                customCommandStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { customCommandStatus = nil }
            case .setTime:
                setTimeStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { setTimeStatus = nil }
            case .battery:
                batteryStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { batteryStatus = nil }
            case .freeMem:
                freeMemStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { freeMemStatus = nil }
            case .uptime:
                uptimeStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { uptimeStatus = nil }
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
                actionRow(
                    label: "Set time",
                    id: .setTime,
                    dirty: false,
                    status: setTimeStatus
                ) {
                    activeButton = .setTime
                    let now = Date()
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = TimeZone.current
                    let y  = cal.component(.year,   from: now)
                    let mo = cal.component(.month,  from: now)
                    let d  = cal.component(.day,    from: now)
                    let h  = cal.component(.hour,   from: now)
                    let mi = cal.component(.minute, from: now)
                    let s  = cal.component(.second, from: now)
                    let mpWday = (cal.component(.weekday, from: now) + 5) % 7
                    let yday = cal.ordinality(of: .day, in: .year, for: now) ?? 1
                    manager.sendCustomCommand(
                        "import wasp;wasp.watch.rtc.set_localtime((\(y),\(mo),\(d),\(h),\(mi),\(s),\(mpWday),\(yday)))"
                    )
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

            Toggle("Enable transmissions", isOn: $manager.transmissionsEnabled)

            pushStatusRow
        }
    }

    @ViewBuilder
    private var pushStatusRow: some View {
        switch manager.pushPhase {
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.75)
                Text("Connecting…").font(.caption).foregroundColor(.secondary)
            }
        case .sending:
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.75)
                Text("Sending…").font(.caption).foregroundColor(.secondary)
            }
        case .purging:
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.75)
                Text("Purging — retrying in ~30 s…").font(.caption).foregroundColor(.secondary)
            }
        case .success:
            EmptyView()
        case .idle:
            if let error = manager.lastPushError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption).foregroundColor(.orange)
                    Text(error).font(.caption).foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        Section(
            header: Text("Configuration"),
            footer: Text("Tap Save to push the selected mode to the watch. Tap Activate to make it the active mode.")
        ) {
            Picker("Mode", selection: Binding(
                get: { selectedPresetIndex },
                set: { newIdx in
                    guard newIdx != selectedPresetIndex else { return }
                    if presetDirty {
                        pendingPresetSwitch = newIdx
                        showUnsavedChangesAlert = true
                    } else {
                        selectedPresetIndex = newIdx
                    }
                }
            )) {
                ForEach(manager.presets.indices, id: \.self) { idx in
                    Text(manager.presets[idx].name).tag(idx)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Name")
                Spacer()
                TextField("mode name", text: Binding(
                    get: { manager.presets[selectedPresetIndex].name },
                    set: { manager.presets[selectedPresetIndex].name = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .foregroundColor(.secondary)
            }

            Toggle("Wake screen on new reading", isOn: Binding(
                get: { manager.presets[selectedPresetIndex].wakeOnReading },
                set: { manager.presets[selectedPresetIndex].wakeOnReading = $0 }
            ))

            Toggle("Haptic on every reading", isOn: Binding(
                get: { manager.presets[selectedPresetIndex].hapOnReading },
                set: { manager.presets[selectedPresetIndex].hapOnReading = $0 }
            ))

            ForEach(manager.presets[selectedPresetIndex].hapticSlots.indices, id: \.self) { idx in
                hapticSlotRow(slotIdx: idx)
            }

            actionRow(
                label: "Activate",
                id: .activatePreset,
                dirty: false,
                status: activatePresetStatus
            ) {
                activeButton = .activatePreset
                manager.activatePreset(at: selectedPresetIndex)
            }

            actionRow(
                label: "Save",
                id: .savePreset,
                dirty: presetDirty,
                status: savePresetStatus
            ) {
                activeButton = .savePreset
                manager.savePreset(at: selectedPresetIndex)
                presetDirty = false
            }

            actionRow(
                label: "Delete mode",
                id: .deletePreset,
                dirty: false,
                status: deletePresetStatus,
                disabled: manager.presets.count == 1 || selectedPresetIndex != manager.presets.count - 1,
                labelColor: .red
            ) {
                activeButton = .deletePreset
                manager.deleteLastPreset()
                selectedPresetIndex = max(0, selectedPresetIndex - 1)
            }

            Button("Add mode") {
                if presetDirty {
                    pendingAddPreset = true
                    showUnsavedChangesAlert = true
                } else {
                    manager.addPreset()
                    selectedPresetIndex = manager.presets.count - 1
                    presetDirty = true
                }
            }
        }
    }

    @ViewBuilder
    private func hapticSlotRow(slotIdx: Int) -> some View {
        let slot = manager.presets[selectedPresetIndex].hapticSlots[slotIdx]
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Haptic slot \(slotIdx + 1)", isOn: Binding(
                get: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].enabled },
                set: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].enabled = $0 }
            ))
            if slot.enabled {
                HStack(spacing: 12) {
                    Picker("", selection: Binding(
                        get: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].op },
                        set: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].op = $0 }
                    )) {
                        Text("Above").tag(">")
                        Text("Below").tag("<")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 130)

                    Stepper(
                        "\(manager.presets[selectedPresetIndex].hapticSlots[slotIdx].thr) mg/dL",
                        value: Binding(
                            get: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].thr },
                            set: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].thr = $0 }
                        ),
                        in: 40...400,
                        step: 10
                    )
                }

                Picker("Pattern", selection: Binding(
                    get: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].pat },
                    set: { manager.presets[selectedPresetIndex].hapticSlots[slotIdx].pat = $0 }
                )) {
                    ForEach(DiaWatchManager.HapticSlot.allPatterns, id: \.self) { pat in
                        Text(Self.formatPattern(pat)).tag(pat)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Test Haptics

    private var testHapticsSection: some View {
        Section(
            header: Text("Test Haptics"),
            footer: Text("Sends a MicroPython command to the watch to play the selected pattern immediately.")
        ) {
            Picker("Pattern", selection: $selectedHapticPattern) {
                ForEach(DiaWatchManager.HapticSlot.allPatterns, id: \.self) { pat in
                    Text(Self.formatPattern(pat)).tag(pat)
                }
            }
            .pickerStyle(.menu)

            actionRow(
                label: "Play",
                id: .testHaptic,
                dirty: false,
                status: testHapticStatus
            ) {
                activeButton = .testHaptic
                manager.testHaptic(name: selectedHapticPattern)
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

            actionRow(
                label: "Get battery",
                id: .battery,
                dirty: false,
                status: batteryStatus
            ) {
                activeButton = .battery
                manager.sendCustomCommand("import wasp;watch.battery.level()")
            }

            actionRow(
                label: "Get free mem",
                id: .freeMem,
                dirty: false,
                status: freeMemStatus
            ) {
                activeButton = .freeMem
                manager.sendCustomCommand("import gc;gc.mem_free()")
            }

            actionRow(
                label: "Get uptime",
                id: .uptime,
                dirty: false,
                status: uptimeStatus
            ) {
                activeButton = .uptime
                manager.sendCustomCommand("import wasp;wasp.uptime()/3600")
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Custom command", text: $customCommandText)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                actionRow(
                    label: "Send",
                    id: .customCommand,
                    dirty: false,
                    status: customCommandStatus
                ) {
                    activeButton = .customCommand
                    manager.sendCustomCommand(customCommandText)
                }
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Last transmission response")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(manager.bleResponse.isEmpty ? "No response yet" : manager.bleResponse)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(manager.bleResponse.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        Color.clear.frame(height: 1).id("ble_bottom")
                    }
                    .frame(height: 120)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
                    .onChange(of: manager.bleResponse) { _ in
                        proxy.scrollTo("ble_bottom", anchor: .bottom)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Shared action row

    private func actionRow(
        label: String,
        id: ActiveButton,
        dirty: Bool,
        status: ButtonStatus?,
        disabled: Bool = false,
        labelColor: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        let isSending = manager.pushPhase != .idle
        let isDisabled = isSending || disabled
        let isActive = activeButton == id

        return HStack {
            Button(action: action) {
                Text(label)
                    .foregroundColor(isDisabled ? .secondary : labelColor)
            }
            .disabled(isDisabled)

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
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
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

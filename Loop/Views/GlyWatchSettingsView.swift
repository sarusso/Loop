//
//  GlyWatchSettingsView.swift
//  Loop
//

import CoreBluetooth
import SwiftUI

struct GlyWatchSettingsView: View {

    @ObservedObject var manager: GlyWatchManager
    @Environment(\.dismiss) private var dismiss

    @State private var gearRotation: Double = 0
    @State private var testMgdl: Int = 190
    @State private var selectedPresetIndex: Int = 0
    @State private var presetDirty = false

    private enum ConfigTab: String, CaseIterable { case general = "General", ranges = "Ranges", alerts = "Alerts" }
    @State private var configTab: ConfigTab = .general
    @State private var generalDirty = false
    @State private var alertsDirty = false
    @State private var rangesDirty = false

    private enum ActiveButton { case none, test, saveGeneral, saveAlerts, saveRanges, activatePreset, deletePreset, testHaptic, customCommand, getLog, getPrevLog, setTime, battery, memFree, memLayout, uptime, ctrlC, resetWatermark, drainReadings }
    @State private var activeButton: ActiveButton = .none

    @FocusState private var presetNameFocused: Bool
    @State private var debugExpanded = false

    struct ButtonStatus {
        var text: String
        var isError: Bool
    }
    @State private var saveGeneralStatus: ButtonStatus? = nil
    @State private var saveAlertsStatus: ButtonStatus? = nil
    @State private var saveRangesStatus: ButtonStatus? = nil
    @State private var activatePresetStatus: ButtonStatus? = nil
    @State private var deletePresetStatus: ButtonStatus? = nil
    @State private var showUnsavedChangesAlert = false
    @State private var showTabChangeAlert = false
    @State private var showNewPresetSaveAlert = false
    @State private var pendingTabSwitch: ConfigTab? = nil
    @State private var pendingPresetSwitch: Int = 0
    @State private var pendingDismiss = false
    @State private var pendingAddPreset = false
    @State private var suppressDirty = false
    @State private var testStatus: ButtonStatus? = nil
    @State private var testHapticStatus: ButtonStatus? = nil
    @State private var selectedHapticPattern: String = GlyWatchManager.HapticAlert.allPatterns[0]
    @State private var customCommandStatus: ButtonStatus? = nil
    @State private var customCommandText: String = ""
    @State private var setTimeStatus: ButtonStatus? = nil
    @State private var batteryStatus: ButtonStatus? = nil
    @State private var memFreeStatus: ButtonStatus? = nil
    @State private var memLayoutStatus: ButtonStatus? = nil
    @State private var uptimeStatus: ButtonStatus? = nil
    @State private var ctrlCStatus: ButtonStatus? = nil
    @State private var resetWatermarkStatus: ButtonStatus? = nil
    @State private var drainReadingsStatus: ButtonStatus? = nil
    @State private var getLogStatus: ButtonStatus? = nil
    @State private var getPrevLogStatus: ButtonStatus? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let responseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd/M/yyyy"
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
        .navigationBarTitle("GlyWatch", displayMode: .inline)
        .dismissKeyboardOnScroll()
        .navigationBarBackButtonHidden(anyDirty)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if anyDirty {
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
        .onChange(of: manager.presets) { _ in
            if suppressDirty { suppressDirty = false; return }
            let savedPresets = UserDefaults.standard.glyWatchPresets
            guard selectedPresetIndex < savedPresets.count else {
                generalDirty = true
                return
            }
            let saved = savedPresets[selectedPresetIndex]
            let current = manager.presets[selectedPresetIndex]
            generalDirty = current.name != saved.name
                || current.wakeOnReading != saved.wakeOnReading
                || current.displayBrightness != saved.displayBrightness
                || current.displayAlwaysOn != saved.displayAlwaysOn
                || current.displaySleepSec != saved.displaySleepSec
                || current.forecaster != saved.forecaster
                || current.od != saved.od
                || current.nd != saved.nd
                || current.st != saved.st
                || current.dt != saved.dt
                || current.lt != saved.lt
                || current.sp != saved.sp
                || current.lp != saved.lp
            alertsDirty = current.hapticAlerts != saved.hapticAlerts
            rangesDirty = current.rangeCutoffs != saved.rangeCutoffs
                || current.rangeHaptics != saved.rangeHaptics
                || current.rangePlayHaptic != saved.rangePlayHaptic
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Discard", role: .destructive) {
                suppressDirty = true
                let savedPresets = UserDefaults.standard.glyWatchPresets
                if selectedPresetIndex < savedPresets.count {
                    manager.presets[selectedPresetIndex] = savedPresets[selectedPresetIndex]
                } else {
                    manager.presets.removeLast()
                    selectedPresetIndex = max(0, manager.presets.count - 1)
                }
                generalDirty = false
                alertsDirty = false
                rangesDirty = false
                if pendingDismiss {
                    pendingDismiss = false
                    dismiss()
                } else if pendingAddPreset {
                    pendingAddPreset = false
                    manager.addPreset()
                    selectedPresetIndex = manager.presets.count - 1
                    configTab = .general
                    generalDirty = true
                } else {
                    selectedPresetIndex = min(pendingPresetSwitch, manager.presets.count - 1)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDismiss = false
                pendingAddPreset = false
            }
        } message: {
            Text("The preset \"\(manager.presets[selectedPresetIndex].name)\" has unsaved changes. Discard them?")
        }
        .alert("Unsaved Changes", isPresented: $showTabChangeAlert) {
            Button("Save", role: .none) {
                if let tab = pendingTabSwitch {
                    switch configTab {
                    case .general:
                        activeButton = .saveGeneral
                        manager.saveGeneralConfig(at: selectedPresetIndex)
                    case .alerts:
                        activeButton = .saveAlerts
                        manager.saveAlerts(at: selectedPresetIndex)
                    case .ranges:
                        activeButton = .saveRanges
                        manager.saveRanges(at: selectedPresetIndex)
                    }
                    configTab = tab
                    pendingTabSwitch = nil
                }
            }
            Button("Discard", role: .destructive) {
                if let tab = pendingTabSwitch {
                    suppressDirty = true
                    let savedPresets = UserDefaults.standard.glyWatchPresets
                    if selectedPresetIndex < savedPresets.count {
                        manager.presets[selectedPresetIndex] = savedPresets[selectedPresetIndex]
                    }
                    switch configTab {
                    case .general: generalDirty = false
                    case .alerts:   alertsDirty = false
                    case .ranges:     rangesDirty = false
                    }
                    configTab = tab
                    pendingTabSwitch = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTabSwitch = nil
            }
        } message: {
            Text("Save changes to \(configTab.rawValue.lowercased()) before switching?")
        }
        .alert("Save Required", isPresented: $showNewPresetSaveAlert) {
            Button("OK", role: .cancel) {
                pendingTabSwitch = nil
            }
        } message: {
            Text("Save this new preset before switching tabs.")
        }
        .onChange(of: manager.pushPhase) { phase in
            guard phase == .idle else { return }

            let isError = manager.lastPushError != nil
            let which = activeButton
            activeButton = .none

            let text: String
            switch which {
            case .test:          text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .saveGeneral:   text = isError ? (manager.lastPushError ?? "Failed") : "Saved!"
            case .saveAlerts:     text = isError ? (manager.lastPushError ?? "Failed") : "Saved!"
            case .saveRanges:     text = isError ? (manager.lastPushError ?? "Failed") : "Saved!"
            case .activatePreset: text = isError ? (manager.lastPushError ?? "Failed") : "Activated!"
            case .deletePreset:   text = isError ? (manager.lastPushError ?? "Failed") : "Deleted!"
            case .testHaptic:    text = isError ? (manager.lastPushError ?? "Failed") : "Played!"
            case .customCommand: text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .getLog:        text = isError ? (manager.lastPushError ?? "Failed") : "Done!"
            case .getPrevLog:    text = isError ? (manager.lastPushError ?? "Failed") : "Done!"
            case .setTime:       text = isError ? (manager.lastPushError ?? "Failed") : "Set!"
            case .battery:       text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .memFree:       text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .memLayout:     text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .uptime:        text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .ctrlC:         text = isError ? (manager.lastPushError ?? "Failed") : "Sent!"
            case .resetWatermark: text = "Reset!"
            case .drainReadings: text = isError ? (manager.lastPushError ?? "Failed") : "Triggered!"
            case .none:          return
            }

            let status = ButtonStatus(text: text, isError: isError)
            switch which {
            case .test:
                testStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testStatus = nil }
            case .saveGeneral:
                saveGeneralStatus = status
                if !isError { generalDirty = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { saveGeneralStatus = nil }
            case .saveAlerts:
                saveAlertsStatus = status
                if !isError { alertsDirty = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { saveAlertsStatus = nil }
            case .saveRanges:
                saveRangesStatus = status
                if !isError { rangesDirty = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { saveRangesStatus = nil }
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
            case .memFree:
                memFreeStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { memFreeStatus = nil }
            case .memLayout:
                memLayoutStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { memLayoutStatus = nil }
            case .uptime:
                uptimeStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { uptimeStatus = nil }
            case .ctrlC:
                ctrlCStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ctrlCStatus = nil }
            case .resetWatermark:
                resetWatermarkStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { resetWatermarkStatus = nil }
            case .drainReadings:
                drainReadingsStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { drainReadingsStatus = nil }
            case .getLog:
                getLogStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { getLogStatus = nil }
            case .getPrevLog:
                getPrevLogStatus = status
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { getPrevLogStatus = nil }
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
                    manager.setTime()
                }
            }

            Toggle("Push readings", isOn: $manager.transmissionsEnabled)

            if let date = manager.lastPushDate {
                HStack {
                    Text("Last push")
                    Spacer()
                    if let value = manager.lastPushValue, let readingDate = manager.lastPushReadingDate {
                        Text("\(Self.timeFormatter.string(from: readingDate)): \(value) mg/dL (sent \(Self.timeFormatter.string(from: date)))")
                            .foregroundColor(.secondary)
                    } else if let value = manager.lastPushValue {
                        Text("\(value) mg/dL at \(Self.timeFormatter.string(from: date))")
                            .foregroundColor(.secondary)
                    } else {
                        Text(Self.timeFormatter.string(from: date))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("No readings pushed yet").foregroundColor(.secondary)
            }

            HStack {
                Text("Pending readings")
                Spacer()
                Text("\(manager.pendingReadingsCount)").foregroundColor(.secondary)
            }

            pushStatusRow
        }
        .onAppear { manager.refreshPendingReadingsCount() }
    }

    private var pushStatusRow: some View {
        HStack(spacing: 5) {
            Text("Status")
            Spacer()
            switch manager.pushPhase {
            case .connecting:
                ProgressView().scaleEffect(0.75)
                Text("Connecting…").foregroundColor(.secondary)
            case .sending:
                ProgressView().scaleEffect(0.75)
                Text("Sending…").foregroundColor(.secondary)
            case .awaitingResponse:
                ProgressView().scaleEffect(0.75)
                Text("Awaiting response…").foregroundColor(.secondary)
            case .streaming:
                ProgressView().scaleEffect(0.75)
                Text("Streaming…").foregroundColor(.secondary)
            case .idle:
                if let error = manager.lastPushError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                    Text("\(error), idle").foregroundColor(.orange)
                } else if manager.hasTransmitted {
                    Text("OK, idle").foregroundColor(.green)
                } else {
                    Text("Idle").foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Configuration

    private var anyDirty: Bool { generalDirty || alertsDirty || rangesDirty }
    private var currentTabDirty: Bool {
        switch configTab {
        case .general: return generalDirty
        case .alerts:   return alertsDirty
        case .ranges:     return rangesDirty
        }
    }

    private func currentTabSaveStatus() -> ButtonStatus? {
        switch configTab {
        case .general: return saveGeneralStatus
        case .alerts:   return saveAlertsStatus
        case .ranges:     return saveRangesStatus
        }
    }

    private func currentTabSaveButtonId() -> ActiveButton {
        switch configTab {
        case .general: return .saveGeneral
        case .alerts:   return .saveAlerts
        case .ranges:     return .saveRanges
        }
    }

    private var configurationSection: some View {
        Section(header: Text("Presets")) {
            HStack {
                Picker("", selection: Binding(
                    get: { selectedPresetIndex },
                    set: { newIdx in
                        guard newIdx != selectedPresetIndex else { return }
                        if anyDirty {
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
                .labelsHidden()
                .padding(.leading, -12)

                Spacer()

                Button {
                    if anyDirty {
                        showUnsavedChangesAlert = true
                    } else {
                        manager.duplicatePreset(at: selectedPresetIndex)
                        selectedPresetIndex = manager.presets.count - 1
                        configTab = .general
                        generalDirty = true
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(manager.presets.count >= GlyWatchManager.maxPresets)
                .padding(.trailing, 12)

                Button {
                    if anyDirty {
                        pendingAddPreset = true
                        showUnsavedChangesAlert = true
                    } else {
                        manager.addPreset()
                        selectedPresetIndex = manager.presets.count - 1
                        configTab = .general
                        generalDirty = true
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(manager.presets.count >= GlyWatchManager.maxPresets)
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
                label: "Delete",
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

            Picker("", selection: Binding(
                get: { configTab },
                set: { newTab in
                    guard newTab != configTab else { return }
                    let isNewPreset = selectedPresetIndex >= UserDefaults.standard.glyWatchPresets.count
                    if isNewPreset {
                        pendingTabSwitch = newTab
                        showNewPresetSaveAlert = true
                    } else if currentTabDirty {
                        pendingTabSwitch = newTab
                        showTabChangeAlert = true
                    } else {
                        configTab = newTab
                    }
                }
            )) {
                ForEach(ConfigTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .listRowSeparator(.hidden, edges: .bottom)

            switch configTab {
            case .general: generalTabContent
            case .alerts:   alertsTabContent
            case .ranges:     rangesTabContent
            }

            actionRow(
                label: "Save",
                id: currentTabSaveButtonId(),
                dirty: currentTabDirty,
                status: currentTabSaveStatus(),
                disabled: !currentTabDirty
            ) {
                switch configTab {
                case .general:
                    activeButton = .saveGeneral
                    manager.saveGeneralConfig(at: selectedPresetIndex)
                case .alerts:
                    activeButton = .saveAlerts
                    manager.saveAlerts(at: selectedPresetIndex)
                case .ranges:
                    activeButton = .saveRanges
                    manager.saveRanges(at: selectedPresetIndex)
                }
            }
        }
    }

    @ViewBuilder
    private var generalTabContent: some View {
        HStack {
            Text("Name")
            Spacer()
            TextField("preset name", text: Binding(
                get: { manager.presets[selectedPresetIndex].name },
                set: { manager.presets[selectedPresetIndex].name = $0 }
            ))
            .multilineTextAlignment(.trailing)
            .foregroundColor(.secondary)
            .focused($presetNameFocused)
            .submitLabel(.done)
            .onSubmit { presetNameFocused = false }
        }

        Picker("Display brightness", selection: Binding(
            get: { manager.presets[selectedPresetIndex].displayBrightness },
            set: { manager.presets[selectedPresetIndex].displayBrightness = $0 }
        )) {
            Text("Low").tag(1)
            Text("Mid").tag(2)
            Text("High").tag(3)
        }
        .pickerStyle(.menu)

        Toggle("Display always on", isOn: Binding(
            get: { manager.presets[selectedPresetIndex].displayAlwaysOn },
            set: { manager.presets[selectedPresetIndex].displayAlwaysOn = $0 }
        ))

        if !manager.presets[selectedPresetIndex].displayAlwaysOn {
            Stepper(
                "Display sleep: \(manager.presets[selectedPresetIndex].displaySleepSec) sec",
                value: Binding(
                    get: { manager.presets[selectedPresetIndex].displaySleepSec },
                    set: { manager.presets[selectedPresetIndex].displaySleepSec = $0 }
                ),
                in: 1...3600,
                step: 1
            )

            Toggle("Display wakes on new readings", isOn: Binding(
                get: { manager.presets[selectedPresetIndex].wakeOnReading },
                set: { manager.presets[selectedPresetIndex].wakeOnReading = $0 }
            ))
        }

        tapActionPicker(label: "Single tap", keyPath: \.st)
        tapActionPicker(label: "Double tap", keyPath: \.dt)
        tapActionPicker(label: "Long tap", keyPath: \.lt)
        tapActionPicker(label: "Short button press", keyPath: \.sp)
        tapActionPicker(label: "Long button press", keyPath: \.lp)

        Picker("Forecaster", selection: Binding(
            get: { manager.presets[selectedPresetIndex].forecaster },
            set: { manager.presets[selectedPresetIndex].forecaster = $0 }
        )) {
            ForEach(GlyWatchManager.Forecaster.allCases, id: \.self) { f in
                Text(f.label).tag(f)
            }
        }
        .pickerStyle(.menu)

        Stepper(
            "Outdated data: \(manager.presets[selectedPresetIndex].od) min",
            value: Binding(
                get: { manager.presets[selectedPresetIndex].od },
                set: { manager.presets[selectedPresetIndex].od = $0 }
            ),
            in: 5...60,
            step: 5
        )

        Stepper(
            "No data: \(manager.presets[selectedPresetIndex].nd) min",
            value: Binding(
                get: { manager.presets[selectedPresetIndex].nd },
                set: { manager.presets[selectedPresetIndex].nd = $0 }
            ),
            in: 10...120,
            step: 5
        )
    }

    @ViewBuilder
    private func tapActionPicker(label: String, keyPath: WritableKeyPath<GlyWatchManager.Preset, GlyWatchManager.ButtonAndTapAction>) -> some View {
        Picker(label, selection: Binding(
            get: { manager.presets[selectedPresetIndex][keyPath: keyPath] },
            set: { manager.presets[selectedPresetIndex][keyPath: keyPath] = $0 }
        )) {
            ForEach(GlyWatchManager.ButtonAndTapAction.allCases, id: \.self) { action in
                Text(action.label).tag(action)
            }
        }
    }

    @ViewBuilder
    private var alertsTabContent: some View {
        ForEach(manager.presets[selectedPresetIndex].hapticAlerts.indices, id: \.self) { idx in
            hapticAlertRow(alertIdx: idx)
        }
    }

    // MARK: - Ranges tab

    private static let rangeLabels = ["Very Low", "Low", "OK", "High", "Very High"]

    private static func hex(_ rgb: UInt32) -> Color {
        Color(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double(rgb         & 0xFF) / 255
        )
    }

    private static let rangeColors: [Color] = [
        hex(0xFB5951),  // Very Low
        hex(0xFF8B7C),  // Low
        hex(0x76D3A6),  // OK
        hex(0xBB9AE7),  // High
        hex(0x8C65D6)   // Very High
    ]

    @ViewBuilder
    private var rangesTabContent: some View {
        ForEach(0..<5, id: \.self) { rangeIdx in
            rangeRow(rangeIdx: rangeIdx)
            if rangeIdx < 4 {
                rangeCutoffRow(cutoffIdx: rangeIdx)
            }
        }
    }

    @ViewBuilder
    private func rangeRow(rangeIdx: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.rangeLabels[rangeIdx])
                .fontWeight(.bold)
            HStack {
                Text("Haptic:")
                Picker("", selection: Binding(
                    get: { manager.presets[selectedPresetIndex].rangeHaptics[rangeIdx] },
                    set: { manager.presets[selectedPresetIndex].rangeHaptics[rangeIdx] = $0 }
                )) {
                    ForEach(GlyWatchManager.HapticAlert.allPatterns, id: \.self) { pat in
                        Text(Self.formatPattern(pat)).tag(pat)
                    }
                }
                .labelsHidden()
            }
            Toggle("Play on new readings", isOn: Binding(
                get: { manager.presets[selectedPresetIndex].rangePlayHaptic[rangeIdx] },
                set: { manager.presets[selectedPresetIndex].rangePlayHaptic[rangeIdx] = $0 }
            ))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rangeCutoffRow(cutoffIdx: Int) -> some View {
        let cutoffs = manager.presets[selectedPresetIndex].rangeCutoffs
        let lower = cutoffIdx == 0 ? 40 : cutoffs[cutoffIdx - 1] + 5
        let upper = cutoffIdx == 3 ? 400 : cutoffs[cutoffIdx + 1] - 5

        Stepper(
            "Cutoff: \(cutoffs[cutoffIdx]) mg/dL",
            value: Binding(
                get: { manager.presets[selectedPresetIndex].rangeCutoffs[cutoffIdx] },
                set: { manager.presets[selectedPresetIndex].rangeCutoffs[cutoffIdx] = $0 }
            ),
            in: lower...max(lower, upper),
            step: 5
        )
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Self.hex(0xFFF7E5))
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color(UIColor.secondarySystemGroupedBackground))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func hapticAlertRow(alertIdx: Int) -> some View {
        let alert = manager.presets[selectedPresetIndex].hapticAlerts[alertIdx]
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Alert \(alertIdx + 1)", isOn: Binding(
                get: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].enabled },
                set: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].enabled = $0 }
            ))
            if alert.enabled {
                HStack(spacing: 12) {
                    Picker("", selection: Binding(
                        get: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].op },
                        set: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].op = $0 }
                    )) {
                        Text("Above").tag(">")
                        Text("Below").tag("<")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 130)

                    Stepper(
                        "\(manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].thr) mg/dL",
                        value: Binding(
                            get: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].thr },
                            set: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].thr = $0 }
                        ),
                        in: 40...400,
                        step: 10
                    )
                }

                Picker("Haptic", selection: Binding(
                    get: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].pat },
                    set: { manager.presets[selectedPresetIndex].hapticAlerts[alertIdx].pat = $0 }
                )) {
                    ForEach(GlyWatchManager.HapticAlert.allPatterns, id: \.self) { pat in
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
            header: Text("Test Haptics")
        ) {
            Picker("Pattern", selection: $selectedHapticPattern) {
                ForEach(GlyWatchManager.HapticAlert.allPatterns, id: \.self) { pat in
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
        Section {
            Button {
                withAnimation { debugExpanded.toggle() }
            } label: {
                HStack {
                    Text("Debug").foregroundColor(.primary)
                    Spacer()
                    Image(systemName: debugExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            if debugExpanded {
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
                label: "Drain pending readings",
                id: .drainReadings,
                dirty: false,
                status: drainReadingsStatus
            ) {
                activeButton = .drainReadings
                drainReadingsStatus = ButtonStatus(text: "Triggered!", isError: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { drainReadingsStatus = nil }
                manager.drainReadings()
            }

            actionRow(
                label: "Reset readings watermark",
                id: .resetWatermark,
                dirty: false,
                status: resetWatermarkStatus
            ) {
                manager.resetReadingsWatermark()
                resetWatermarkStatus = ButtonStatus(text: "Reset!", isError: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { resetWatermarkStatus = nil }
            }

            actionRow(
                label: "Get battery",
                id: .battery,
                dirty: false,
                status: batteryStatus
            ) {
                activeButton = .battery
                manager.sendCustomCommand("import utils; utils.get_battery_level()")
            }

            actionRow(
                label: "Get uptime",
                id: .uptime,
                dirty: false,
                status: uptimeStatus
            ) {
                activeButton = .uptime
                manager.sendCustomCommand("import utils; utils.get_uptime()")
            }

            actionRow(
                label: "Get mem free",
                id: .memFree,
                dirty: false,
                status: memFreeStatus
            ) {
                activeButton = .memFree
                manager.sendCustomCommand("import utils; utils.get_mem_free()")
            }

            actionRow(
                label: "Get mem layout",
                id: .memLayout,
                dirty: false,
                status: memLayoutStatus
            ) {
                activeButton = .memLayout
                manager.sendCustomCommand("import utils; utils.get_mem_layout()")
            }

            // NOTE: Do NOT remove these commented-out log buttons. Keep them here
            // for quick re-enablement when debugging watch-side issues.
            //
            // actionRow(
            //     label: "Get log",
            //     id: .getLog,
            //     dirty: false,
            //     status: getLogStatus
            // ) {
            //     activeButton = .getLog
            //     manager.sendCustomCommand("wasp.log_dump()")
            // }
            //
            // actionRow(
            //     label: "Get prev log",
            //     id: .getPrevLog,
            //     dirty: false,
            //     status: getPrevLogStatus
            // ) {
            //     activeButton = .getPrevLog
            //     manager.sendCustomCommand("wasp.log_pre_dump()")
            // }

            actionRow(
                label: "Send Ctrl-C",
                id: .ctrlC,
                dirty: false,
                status: ctrlCStatus
            ) {
                activeButton = .ctrlC
                manager.sendCustomCommand("\u{03}")
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

            if manager.isStreaming {
                Button {
                    manager.stopLogStream()
                } label: {
                    HStack {
                        Image(systemName: "stop.circle.fill").foregroundColor(.red)
                        Text("Stop log stream").foregroundColor(.red)
                    }
                }
            } else {
                Button {
                    debugExpanded = true
                    manager.startLogStream()
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Start log stream")
                    }
                }
                .disabled(manager.pushPhase != .idle)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(manager.lastResponseDate.map { "Last transmission response (@ \(Self.responseDateFormatter.string(from: $0)))" } ?? "Last transmission response")
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

            NavigationLink(destination: GlyWatchCommandLogView(manager: manager)) {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Open command log")
                    Spacer()
                    Text("\(manager.commandLog.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            }
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

private extension View {
    @ViewBuilder
    func dismissKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}

//
//  DiaWatchSettingsView.swift
//  Loop
//

import CoreBluetooth
import SwiftUI

struct DiaWatchSettingsView: View {

    @ObservedObject var manager: DiaWatchManager

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        Form {
            pairedDeviceSection
            statusSection
            if manager.isScanning || !manager.discoveredDevices.isEmpty {
                discoveredDevicesSection
            }
        }
        .navigationBarTitle("DiaWatch", displayMode: .inline)
    }

    // MARK: - Sections

    private var pairedDeviceSection: some View {
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
                    ProgressView()
                    Text("Scanning…").padding(.leading, 8).foregroundColor(.secondary)
                    Spacer()
                    Button("Stop") { manager.stopScan() }
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
            if let date = manager.lastPushDate {
                HStack {
                    Text("Last push")
                    Spacer()
                    Text(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
                        .foregroundColor(.secondary)
                }
            }
            if let error = manager.lastPushError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).font(.caption)
                }
            }
            if manager.lastPushDate == nil && manager.lastPushError == nil {
                Text("No readings sent yet").foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var discoveredDevicesSection: some View {
        Section(header: Text("Found Devices")) {
            if manager.discoveredDevices.isEmpty {
                Text("Scanning for nearby BLE devices…")
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.discoveredDevices, id: \.identifier) { device in
                    Button(action: { manager.pair(device) }) {
                        HStack {
                            Text(device.name ?? "Unknown Device").foregroundColor(.primary)
                            Spacer()
                            Text("Pair").foregroundColor(.accentColor)
                        }
                    }
                }
            }
        }
    }
}

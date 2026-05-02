//
//  GlyWatchCommandLogView.swift
//  Loop
//

import SwiftUI

struct GlyWatchCommandLogView: View {
    @ObservedObject var manager: GlyWatchManager
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case ok = "OK"
        case errors = "Errors"
        var id: String { rawValue }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private var filteredEntries: [GlyWatchManager.CommandLogEntry] {
        switch filter {
        case .all:    return manager.commandLog
        case .ok:     return manager.commandLog.filter { !$0.isError }
        case .errors: return manager.commandLog.filter { $0.isError }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if filteredEntries.isEmpty {
                Spacer()
                Text(manager.commandLog.isEmpty ? "No commands sent yet" : "No entries match the current filter")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredEntries) { entry in
                            CommandLogCard(entry: entry, formatter: Self.timeFormatter)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationBarTitle("Command log", displayMode: .inline)
    }
}

private struct CommandLogCard: View {
    let entry: GlyWatchManager.CommandLogEntry
    let formatter: DateFormatter

    private var borderColor: Color {
        entry.isUserTriggered ? .blue : .gray
    }

    private var statusColor: Color {
        entry.isError ? .red : .green
    }

    private var responseColor: Color {
        entry.isError ? .red : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(entry.status)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(statusColor)
            }

            Text(entry.command.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Divider()

            Text(entry.response.isEmpty ? "(no response)" : entry.response)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(entry.response.isEmpty ? .secondary : responseColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1.5)
        )
    }
}

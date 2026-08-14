//
//  PluginManagementView.swift
//  deepseek launcher
//

import SwiftUI

struct PluginManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PluginStore()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Plugins")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Syncing plugins")
                        }
                        Button(action: store.refresh) {
                            Label("Sync Plugins", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                        .help("Sync installed plugins")
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 400)
        .task { store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Syncing plugins…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where store.plugins.isEmpty:
            ContentUnavailableView(
                "No plugins installed",
                systemImage: "puzzlepiece.extension",
                description: Text("Plugins you install later will appear here.")
            )
        case .loaded:
            List(store.plugins) { plugin in
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.tint)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.name)
                            .font(.body.weight(.medium))
                        Text("Version \(plugin.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(plugin.status.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                        Text(plugin.source.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(plugin.name), version \(plugin.version), \(plugin.status.rawValue), \(plugin.source.rawValue)")
            }
            .listStyle(.inset)
        case let .failed(message):
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Couldn't sync plugins",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                Button("Try Again", action: store.refresh)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

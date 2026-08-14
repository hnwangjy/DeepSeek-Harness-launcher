//
//  PluginManagementView.swift
//  deepseek launcher
//

import SwiftUI

struct PluginManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PluginStore()
    @State private var pendingInstallation: PluginCatalogItem?
    @State private var showsModLensConfigurationInfo = false
    let onInstallationSucceeded: () -> Void

    init(onInstallationSucceeded: @escaping () -> Void = {}) {
        self.onInstallationSucceeded = onInstallationSucceeded
    }

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
                        .disabled(store.isBusy)
                        .help("Sync installed plugins")
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .disabled(store.isInstalling)
                    }
                }
        }
        .frame(minWidth: 620, minHeight: 520)
        .task { store.refresh() }
        .alert("Install plugin?", isPresented: pendingInstallationBinding) {
            Button("Cancel", role: .cancel) { pendingInstallation = nil }
            Button("Install") {
                guard let plugin = pendingInstallation else { return }
                pendingInstallation = nil
                store.install(plugin) { succeeded in
                    guard succeeded else { return }
                    dismiss()
                    onInstallationSucceeded()
                }
            }
        } message: {
            if let plugin = pendingInstallation {
                Text("Source: \(plugin.source)\n\n\(riskSummary(for: plugin))")
            }
        }
        .alert("ModLens configuration", isPresented: $showsModLensConfigurationInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("ModLens needs a visual engine selection before it can be used. This launcher does not open or connect Codex, Claude, OpenCode, accounts, or API keys.")
        }
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
        default:
            List {
                Section("Available plugins") {
                    ForEach(store.rows) { row in
                        catalogRow(row)
                    }
                }
                if !store.additionalInstalledPlugins.isEmpty {
                    Section("Other installed plugins") {
                        ForEach(store.additionalInstalledPlugins) { plugin in
                            installedPluginRow(plugin)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay(alignment: .topTrailing) {
                if store.isRefreshing {
                    Text("Syncing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
    }

    private func catalogRow(_ row: CatalogPluginRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.catalog.name)
                    .font(.body.weight(.semibold))
                Text(row.catalog.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Source: \(row.catalog.source)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                versionText(for: row)
                if case let .installing(step) = row.state {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(step)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if case let .failed(message) = row.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                if case let .blocked(message) = row.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                statusLabel(row.state)
                rowAction(row)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.catalog.name), \(row.state.title), target version \(row.catalog.targetVersion)")
    }

    private func installedPluginRow(_ plugin: HarnessPlugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name).font(.body.weight(.medium))
                Text("Version \(plugin.version) · \(plugin.source.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(plugin.status.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func versionText(for row: CatalogPluginRow) -> some View {
        switch row.state {
        case let .active(installedVersion), let .updateAvailable(installedVersion), let .needsConfiguration(installedVersion):
            Text("Installed \(installedVersion) · Target \(row.catalog.targetVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        default:
            Text("Target version \(row.catalog.targetVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rowAction(_ row: CatalogPluginRow) -> some View {
        switch row.state {
        case .notInstalled, .failed:
            Button(row.state.title == "Failed" ? "Retry" : "Install") {
                pendingInstallation = row.catalog
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
        case .needsConfiguration:
            Button("Configuration") { showsModLensConfigurationInfo = true }
                .disabled(store.isBusy)
        case .blocked:
            Text("Blocked")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .installing:
            EmptyView()
        case .active, .updateAvailable:
            EmptyView()
        }
    }

    private func statusLabel(_ state: CatalogPluginState) -> some View {
        Text(state.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor(for: state))
    }

    private func statusColor(for state: CatalogPluginState) -> Color {
        switch state {
        case .active: return .green
        case .needsConfiguration, .blocked, .updateAvailable: return .orange
        case .failed: return .red
        case .installing: return .accentColor
        case .notInstalled: return .secondary
        }
    }

    private var pendingInstallationBinding: Binding<Bool> {
        Binding(
            get: { pendingInstallation != nil },
            set: { if !$0 { pendingInstallation = nil } }
        )
    }

    private func riskSummary(for plugin: PluginCatalogItem) -> String {
        switch plugin.safety {
        case let .standard(riskSummary): return riskSummary
        case let .requiresExplicitBuildApproval(reason): return reason
        }
    }
}

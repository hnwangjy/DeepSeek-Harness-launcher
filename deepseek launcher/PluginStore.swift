//
//  PluginStore.swift
//  deepseek launcher
//

import Combine
import Foundation

nonisolated struct HarnessPlugin: Identifiable, Equatable, Sendable {
    nonisolated enum Source: String, Equatable, Sendable {
        case webProfile = "Web profile"
    }

    nonisolated enum Status: String, Equatable, Sendable {
        case active = "Active"
    }

    let id: String
    let name: String
    let version: String
    let source: Source
    let status: Status
}

/// The boundary for discovering installed Harness plugins.
///
/// DSH currently manages plugins through `dsh plugin --profile web <pnpm args>`.
/// This first native UI phase is intentionally read-only: it reads the same web
/// profile manifest that DSH reconciles after a plugin command completes.
protocol PluginManaging: Sendable {
    nonisolated func discoverPlugins() throws -> [HarnessPlugin]
}

struct DSHProfilePluginManager: PluginManaging {
    private let profileDirectory: URL

    nonisolated init(profileDirectory: URL? = nil) {
        self.profileDirectory = profileDirectory ?? Self.defaultProfileDirectory()
    }

    nonisolated func discoverPlugins() throws -> [HarnessPlugin] {
        let profileManifestURL = profileDirectory.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: profileManifestURL.path) else {
            return []
        }

        let profileData = try Data(contentsOf: profileManifestURL)
        guard let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
            throw PluginDiscoveryError.invalidProfileManifest
        }
        let profileConfiguration = (profile["dsh"] as? [String: Any])?["profile"] as? [String: Any]
        let activeBundles = Set(profileConfiguration?["bundles"] as? [String] ?? [])
        let dependencies = profile["dependencies"] as? [String: String] ?? [:]

        guard !activeBundles.isEmpty else { return [] }

        var plugins: [HarnessPlugin] = []
        for (packageName, declaredVersion) in dependencies where activeBundles.contains(packageName) {
            let installedManifestURL = profileDirectory
                .appendingPathComponent("node_modules", isDirectory: true)
                .appendingPathComponent(packageName, isDirectory: true)
                .appendingPathComponent("package.json")

            guard FileManager.default.fileExists(atPath: installedManifestURL.path) else { continue }

            let installedData = try Data(contentsOf: installedManifestURL)
            guard declaresPluginBundle(installedData) else { continue }
            guard let installed = try JSONSerialization.jsonObject(with: installedData) as? [String: Any] else {
                continue
            }
            let stableName = installed["name"] as? String ?? packageName

            plugins.append(HarnessPlugin(
                id: stableName,
                name: stableName,
                version: installed["version"] as? String ?? declaredVersion,
                source: .webProfile,
                status: .active
            ))
        }

        return plugins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func defaultProfileDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("DeepSeek Harness", isDirectory: true)
            .appendingPathComponent("dsh-home", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)
    }

    private nonisolated func declaresPluginBundle(_ data: Data) -> Bool {
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = manifest["dsh"] as? [String: Any],
              let bundle = dsh["bundle"] as? [String: Any] else {
            return false
        }
        return bundle["patch"] != nil
    }
}

@MainActor
final class PluginStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var plugins: [HarnessPlugin] = []

    private let manager: any PluginManaging
    private var refreshTask: Task<Void, Never>?

    var isRefreshing: Bool {
        state == .loading
    }

    init(manager: any PluginManaging = DSHProfilePluginManager()) {
        self.manager = manager
    }

    deinit {
        refreshTask?.cancel()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        state = .loading

        let manager = manager
        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            do {
                let discovered = try await Task.detached(priority: .userInitiated) {
                    try manager.discoverPlugins()
                }.value
                guard !Task.isCancelled else { return }
                self?.plugins = discovered
                self?.state = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }
}

private enum PluginDiscoveryError: LocalizedError {
    case invalidProfileManifest

    var errorDescription: String? {
        switch self {
        case .invalidProfileManifest:
            return "The web profile manifest is invalid."
        }
    }
}

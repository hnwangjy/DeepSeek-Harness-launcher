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

nonisolated struct PluginCatalogItem: Identifiable, Equatable, Sendable {
    enum InstallationSafety: Equatable, Sendable {
        case standard(riskSummary: String)
        case requiresExplicitBuildApproval(reason: String)
    }

    let id: String
    let name: String
    let summary: String
    let source: String
    let targetVersion: String
    let installSpecifier: String
    let needsConfiguration: Bool
    let safety: InstallationSafety

    static let reviewed: [PluginCatalogItem] = [
        PluginCatalogItem(
            id: "dsh-at-file",
            name: "dsh-at-file",
            summary: "Adds file navigation and file mentions to the web workspace.",
            source: "GitHub release tarball",
            targetVersion: "0.4.0",
            installSpecifier: "https://github.com/omdsh-dev/dsh-at-file/archive/refs/tags/v0.4.0.tar.gz",
            needsConfiguration: false,
            safety: .standard(riskSummary: "Installs the reviewed v0.4.0 release package into the local DSH web profile.")
        ),
        PluginCatalogItem(
            id: "@omdsh-dev/dsh-genui",
            name: "dsh-genui",
            summary: "Adds generated UI capabilities to DeepSeek Harness.",
            source: "GitHub tag v0.8.0 (commit ceab0ed)",
            targetVersion: "0.8.1",
            installSpecifier: "git+https://github.com/omdsh-dev/dsh-genui.git#ceab0edebba254c282f6d984f897da68426b9439",
            needsConfiguration: false,
            safety: .standard(riskSummary: "Installs the reviewed GitHub source pinned to the v0.8.0 commit. No script approval is granted automatically.")
        ),
        PluginCatalogItem(
            id: "dsh-better-sidebar",
            name: "DSH-better-sidebar",
            summary: "Provides an enhanced sidebar with terminal, Git, and file access features.",
            source: "npm: dsh-better-sidebar@0.10.3",
            targetVersion: "0.10.3",
            installSpecifier: "dsh-better-sidebar@0.10.3",
            needsConfiguration: false,
            safety: .requiresExplicitBuildApproval(reason: "This plugin uses terminal, Git, and file access capabilities and depends on native node-pty builds. It needs a precise build-script approval before it can be installed safely.")
        ),
        PluginCatalogItem(
            id: "@liustack/modlens",
            name: "ModLens",
            summary: "Adds ModLens visual tooling to DeepSeek Harness.",
            source: "npm: @liustack/modlens@3.14.0",
            targetVersion: "3.14.0",
            installSpecifier: "@liustack/modlens@3.14.0",
            needsConfiguration: true,
            safety: .standard(riskSummary: "Installs only the DSH plugin package. No Codex, Claude, OpenCode, account, or API key is read or connected.")
        )
    ]
}

nonisolated enum CatalogPluginState: Equatable, Sendable {
    case notInstalled
    case installing(String)
    case active(installedVersion: String)
    case updateAvailable(installedVersion: String)
    case needsConfiguration(installedVersion: String)
    case blocked(String)
    case failed(String)

    var title: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installing: return "Installing"
        case .active: return "Active"
        case .updateAvailable: return "Update available"
        case .needsConfiguration: return "Needs configuration"
        case .blocked: return "Needs approval"
        case .failed: return "Failed"
        }
    }
}

nonisolated struct CatalogPluginRow: Identifiable, Equatable, Sendable {
    let catalog: PluginCatalogItem
    var state: CatalogPluginState

    var id: String { catalog.id }
}

/// The boundary for discovering installed Harness plugins.
/// DSH reconciles a web profile after `dsh plugin --profile web add <specifier>`.
protocol PluginManaging: Sendable {
    nonisolated func discoverPlugins() throws -> [HarnessPlugin]
}

nonisolated struct PluginProcessResult: Sendable {
    let status: Int32
    let output: String
}

protocol ProcessRunning: Sendable {
    nonisolated func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> PluginProcessResult
}

nonisolated struct FoundationProcessRunner: ProcessRunning {
    nonisolated func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> PluginProcessResult {
        let outputPipe = Pipe()
        let collector = ProcessOutputCollector()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        let remaining = outputPipe.fileHandleForReading.readDataToEndOfFile()
        collector.append(remaining)
        let capturedOutput = String(data: collector.data, encoding: .utf8) ?? ""

        return PluginProcessResult(status: process.terminationStatus, output: capturedOutput)
    }
}

protocol PluginInstalling: Sendable {
    nonisolated func install(_ plugin: PluginCatalogItem) throws -> PluginProcessResult
}

/// Installs only through DSH's documented profile command. It uses an isolated,
/// app-managed environment and intentionally does not inherit shell, account, or
/// credential variables from the user session.
nonisolated struct DSHPluginInstaller: PluginInstalling {
    private let paths: ManagedDSHPaths
    private let runner: any ProcessRunning

    nonisolated init(paths: ManagedDSHPaths = .current(), runner: any ProcessRunning = FoundationProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    nonisolated func install(_ plugin: PluginCatalogItem) throws -> PluginProcessResult {
        guard case .standard = plugin.safety else {
            throw PluginInstallationError.approvalRequired(plugin.name)
        }
        try FileManager.default.createDirectory(at: paths.dshHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: paths.npmConfig.path) {
            FileManager.default.createFile(atPath: paths.npmConfig.path, contents: Data())
        }

        guard FileManager.default.isExecutableFile(atPath: paths.node.path),
              FileManager.default.isExecutableFile(atPath: paths.npm.path),
              FileManager.default.fileExists(atPath: paths.dsh.path) else {
            throw PluginInstallationError.harnessUnavailable
        }

        if !FileManager.default.isExecutableFile(atPath: paths.pnpm.path) {
            let pnpmResult = try runner.run(
                executable: paths.npm,
                arguments: ["install", "--no-audit", "--no-fund", "--no-package-lock", "--prefix", paths.harness.path, "pnpm@10.14.0"],
                currentDirectory: paths.workspace,
                environment: environment()
            )
            guard pnpmResult.status == 0 else {
                throw PluginInstallationError.bootstrapFailed(pnpmResult.output)
            }
        }

        let result = try runner.run(
            executable: paths.node,
            arguments: [paths.dsh.path, "plugin", "--profile", "web", "add", plugin.installSpecifier],
            currentDirectory: paths.workspace,
            environment: environment()
        )
        guard result.status == 0 else {
            throw PluginInstallationError.commandFailed(result.output)
        }
        return result
    }

    private nonisolated func environment() -> [String: String] {
        [
            "PATH": "\(paths.harness.appendingPathComponent("node_modules/.bin").path):\(paths.runtime.appendingPathComponent("bin").path):/usr/bin:/bin",
            "DSH_HOME": paths.dshHome.path,
            "NPM_CONFIG_USERCONFIG": paths.npmConfig.path,
            "NPM_CONFIG_GLOBALCONFIG": paths.root.appendingPathComponent("empty-npm-globalrc").path,
            "NPM_CONFIG_CACHE": paths.root.appendingPathComponent("npm-cache").path,
            "NPM_CONFIG_AUDIT": "false",
            "NPM_CONFIG_FUND": "false",
            "NPM_CONFIG_UPDATE_NOTIFIER": "false",
            "PNPM_HOME": paths.root.appendingPathComponent("pnpm-home").path
        ]
    }
}

nonisolated struct DSHProfilePluginManager: PluginManaging {
    private let profileDirectory: URL

    nonisolated init(profileDirectory: URL? = nil) {
        self.profileDirectory = profileDirectory ?? ManagedDSHPaths.current().profile
    }

    nonisolated func discoverPlugins() throws -> [HarnessPlugin] {
        let profileManifestURL = profileDirectory.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: profileManifestURL.path) else { return [] }

        let profileData = try Data(contentsOf: profileManifestURL)
        guard let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
            throw PluginDiscoveryError.invalidProfileManifest
        }
        let profileConfiguration = (profile["dsh"] as? [String: Any])?["profile"] as? [String: Any]
        let activeBundles = Set(profileConfiguration?["bundles"] as? [String] ?? [])
        let dependencies = profile["dependencies"] as? [String: String] ?? [:]

        var plugins: [HarnessPlugin] = []
        for (packageName, declaredVersion) in dependencies where activeBundles.contains(packageName) {
            let installedManifestURL = profileDirectory
                .appendingPathComponent("node_modules", isDirectory: true)
                .appendingPathComponent(packageName, isDirectory: true)
                .appendingPathComponent("package.json")
            guard FileManager.default.fileExists(atPath: installedManifestURL.path) else { continue }

            let installedData = try Data(contentsOf: installedManifestURL)
            guard declaresPluginBundle(installedData),
                  let installed = try JSONSerialization.jsonObject(with: installedData) as? [String: Any] else { continue }
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

    private nonisolated func declaresPluginBundle(_ data: Data) -> Bool {
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = manifest["dsh"] as? [String: Any],
              let bundle = dsh["bundle"] as? [String: Any] else { return false }
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
    @Published private(set) var rows: [CatalogPluginRow] = PluginCatalogItem.reviewed.map { item in
        CatalogPluginRow(catalog: item, state: initialState(for: item))
    }
    @Published private(set) var additionalInstalledPlugins: [HarnessPlugin] = []

    private let manager: any PluginManaging
    private let installer: any PluginInstalling
    private var refreshTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    var isRefreshing: Bool { state == .loading }
    var isInstalling: Bool { installTask != nil }
    var isBusy: Bool { isRefreshing || isInstalling }

    init(
        manager: any PluginManaging = DSHProfilePluginManager(),
        installer: any PluginInstalling = DSHPluginInstaller()
    ) {
        self.manager = manager
        self.installer = installer
    }

    deinit {
        refreshTask?.cancel()
        installTask?.cancel()
    }

    func refresh() {
        guard refreshTask == nil, installTask == nil else { return }
        state = .loading
        let manager = manager
        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            do {
                let discovered = try await Task.detached(priority: .userInitiated) { try manager.discoverPlugins() }.value
                guard !Task.isCancelled else { return }
                self?.apply(discovered)
                self?.state = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func install(_ item: PluginCatalogItem, completion: @escaping @MainActor (Bool) -> Void) {
        guard installTask == nil, refreshTask == nil else { return }
        guard case .standard = item.safety else {
            update(item.id, to: .blocked(blockedMessage(for: item)))
            completion(false)
            return
        }

        update(item.id, to: .installing("Preparing app-managed runtime"))
        let installer = installer
        let manager = manager
        installTask = Task { [weak self] in
            defer { self?.installTask = nil }
            do {
                self?.update(item.id, to: .installing("Installing into the web profile"))
                _ = try await Task.detached(priority: .userInitiated) { try installer.install(item) }.value
                self?.update(item.id, to: .installing("Verifying installed plugin"))
                let discovered = try await Task.detached(priority: .userInitiated) { try manager.discoverPlugins() }.value
                guard !Task.isCancelled else { return }
                self?.apply(discovered)
                completion(true)
            } catch {
                guard !Task.isCancelled else { return }
                self?.update(item.id, to: .failed(error.localizedDescription))
                completion(false)
            }
        }
    }

    func state(for item: PluginCatalogItem) -> CatalogPluginState {
        rows.first(where: { $0.id == item.id })?.state ?? .notInstalled
    }

    private func apply(_ discovered: [HarnessPlugin]) {
        let discoveredByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        rows = PluginCatalogItem.reviewed.map { item in
            if let installed = discoveredByID[item.id] {
                if item.needsConfiguration {
                    return CatalogPluginRow(catalog: item, state: .needsConfiguration(installedVersion: installed.version))
                }
                if installed.version == item.targetVersion {
                    return CatalogPluginRow(catalog: item, state: .active(installedVersion: installed.version))
                }
                return CatalogPluginRow(catalog: item, state: .updateAvailable(installedVersion: installed.version))
            }
            if let existing = rows.first(where: { $0.id == item.id }), case let .failed(message) = existing.state {
                return CatalogPluginRow(catalog: item, state: .failed(message))
            }
            return CatalogPluginRow(catalog: item, state: Self.initialState(for: item))
        }
        additionalInstalledPlugins = discovered.filter { plugin in
            !PluginCatalogItem.reviewed.contains(where: { catalog in catalog.id == plugin.id })
        }
    }

    private func update(_ id: String, to state: CatalogPluginState) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }

    private func blockedMessage(for item: PluginCatalogItem) -> String {
        if case let .requiresExplicitBuildApproval(reason) = item.safety { return reason }
        return "This plugin requires approval."
    }

    private static func initialState(for item: PluginCatalogItem) -> CatalogPluginState {
        if case let .requiresExplicitBuildApproval(reason) = item.safety { return .blocked(reason) }
        return .notInstalled
    }
}

private nonisolated final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    nonisolated func append(_ data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    nonisolated var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }
}

nonisolated struct ManagedDSHPaths: Sendable {
    let root: URL
    let runtime: URL
    let harness: URL
    let dshHome: URL
    let workspace: URL

    var node: URL { runtime.appendingPathComponent("bin/node") }
    var npm: URL { runtime.appendingPathComponent("bin/npm") }
    var pnpm: URL { harness.appendingPathComponent("node_modules/.bin/pnpm") }
    var dsh: URL { harness.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js") }
    var npmConfig: URL { root.appendingPathComponent("managed-npmrc") }
    var profile: URL { dshHome.appendingPathComponent("profiles/web", isDirectory: true) }

    nonisolated static func current() -> ManagedDSHPaths {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = applicationSupport.appendingPathComponent("DeepSeek Harness", isDirectory: true)
        return ManagedDSHPaths(
            root: root,
            runtime: root.appendingPathComponent("runtime", isDirectory: true),
            harness: root.appendingPathComponent("harness", isDirectory: true),
            dshHome: root.appendingPathComponent("dsh-home", isDirectory: true),
            workspace: root.appendingPathComponent("workspace", isDirectory: true)
        )
    }
}

private enum PluginDiscoveryError: LocalizedError {
    case invalidProfileManifest

    var errorDescription: String? {
        "The web profile manifest is invalid."
    }
}

private enum PluginInstallationError: LocalizedError {
    case harnessUnavailable
    case bootstrapFailed(String)
    case commandFailed(String)
    case approvalRequired(String)

    var errorDescription: String? {
        switch self {
        case .harnessUnavailable:
            return "DeepSeek Harness is not ready. Start it before installing a plugin."
        case let .bootstrapFailed(output):
            return concise("Couldn't prepare the managed plugin runtime.", output)
        case let .commandFailed(output):
            return concise("DSH couldn't install this plugin.", output)
        case let .approvalRequired(name):
            return "\(name) needs a specific build-script approval before it can be installed."
        }
    }

    private func concise(_ prefix: String, _ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prefix }
        return "\(prefix) \(String(trimmed.prefix(800)))"
    }
}

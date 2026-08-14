//
//  deepseek_launcherTests.swift
//  deepseek launcherTests
//
//  Created by wjy on 2026/8/14.
//

import Testing
import Foundation
@testable import deepseek_launcher

struct deepseek_launcherTests {

    @Test func discoversOnlyActivatedProfilePluginBundles() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekHarnessPluginTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profileDirectory) }

        try FileManager.default.createDirectory(
            at: profileDirectory.appendingPathComponent("node_modules/example-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )

        let profile = """
        {
          "dependencies": {
            "example-plugin": "^1.2.0",
            "ordinary-library": "^3.0.0"
          },
          "dsh": {
            "profile": {
              "bundles": ["@deepseek-ai/dsh-base", "example-plugin"]
            }
          }
        }
        """
        try Data(profile.utf8).write(to: profileDirectory.appendingPathComponent("package.json"))

        let pluginManifest = """
        {
          "name": "example-plugin",
          "version": "1.2.3",
          "dsh": {
            "bundle": {
              "patch": "cordis.yml"
            }
          }
        }
        """
        try Data(pluginManifest.utf8).write(
            to: profileDirectory.appendingPathComponent("node_modules/example-plugin/package.json")
        )

        let plugins = try DSHProfilePluginManager(profileDirectory: profileDirectory).discoverPlugins()

        #expect(plugins == [
            HarnessPlugin(
                id: "example-plugin",
                name: "example-plugin",
                version: "1.2.3",
                source: .webProfile,
                status: .active
            )
        ])
    }

    @Test @MainActor func catalogPinsReviewedSpecifiers() {
        let catalog = Dictionary(uniqueKeysWithValues: PluginCatalogItem.reviewed.map { ($0.id, $0) })

        #expect(catalog["dsh-at-file"]?.installSpecifier == "https://github.com/omdsh-dev/dsh-at-file/archive/refs/tags/v0.4.0.tar.gz")
        #expect(catalog["@omdsh-dev/dsh-genui"]?.installSpecifier.contains("#ceab0edebba254c282f6d984f897da68426b9439") == true)
        #expect(catalog["dsh-better-sidebar"]?.installSpecifier == "dsh-better-sidebar@0.10.3")
        #expect(catalog["@liustack/modlens"]?.installSpecifier == "@liustack/modlens@3.14.0")
    }

    @Test @MainActor func storeMergesInstalledPluginStatus() async throws {
        let manager = StubPluginManager(plugins: [
            HarnessPlugin(id: "@liustack/modlens", name: "@liustack/modlens", version: "3.14.0", source: .webProfile, status: .active)
        ])
        let store = PluginStore(manager: manager, installer: StubPluginInstaller())

        store.refresh()
        await waitForStore(store)

        #expect(store.state == .loaded)
        #expect(store.state(for: PluginCatalogItem.reviewed[3]) == .needsConfiguration(installedVersion: "3.14.0"))
    }

    @Test @MainActor func successfulInstallDoesNotRunTwice() async throws {
        let manager = StubPluginManager(plugins: [
            HarnessPlugin(id: "dsh-at-file", name: "dsh-at-file", version: "0.4.0", source: .webProfile, status: .active)
        ])
        let installer = StubPluginInstaller()
        let store = PluginStore(manager: manager, installer: installer)
        let plugin = PluginCatalogItem.reviewed[0]
        var completions: [Bool] = []

        store.install(plugin) { completions.append($0) }
        store.install(plugin) { completions.append($0) }
        await waitForInstallation(store)

        #expect(installer.callCount == 1)
        #expect(completions == [true])
        #expect(store.state(for: plugin) == .active(installedVersion: "0.4.0"))
    }

    @Test @MainActor func failedInstallRetainsRetryState() async throws {
        let installer = StubPluginInstaller(shouldFail: true)
        let store = PluginStore(manager: StubPluginManager(plugins: []), installer: installer)
        let plugin = PluginCatalogItem.reviewed[1]

        store.install(plugin) { _ in }
        await waitForInstallation(store)

        guard case .failed = store.state(for: plugin) else {
            Issue.record("A failed installation should remain retryable.")
            return
        }
    }

}

@MainActor
private func waitForStore(_ store: PluginStore) async {
    for _ in 0..<100 where store.isRefreshing {
        await Task.yield()
    }
}

@MainActor
private func waitForInstallation(_ store: PluginStore) async {
    for _ in 0..<100 where store.isInstalling {
        await Task.yield()
    }
}

private nonisolated final class StubPluginManager: PluginManaging, @unchecked Sendable {
    private let plugins: [HarnessPlugin]

    nonisolated init(plugins: [HarnessPlugin]) {
        self.plugins = plugins
    }

    nonisolated func discoverPlugins() throws -> [HarnessPlugin] {
        plugins
    }
}

private nonisolated final class StubPluginInstaller: PluginInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let shouldFail: Bool
    private var calls = 0

    nonisolated init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    nonisolated var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    nonisolated func install(_ plugin: PluginCatalogItem) throws -> PluginProcessResult {
        lock.lock()
        calls += 1
        lock.unlock()
        if shouldFail { throw StubInstallError.failed }
        return PluginProcessResult(status: 0, output: "installed")
    }
}

private nonisolated enum StubInstallError: Error {
    case failed
}

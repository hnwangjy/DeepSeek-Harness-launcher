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

    @Test func parsesSingleCurrencyBalanceWithDecimalPrecision() throws {
        let snapshot = try BalancePayloadParser.parse("""
        {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"19.15","granted_balance":"0.00","topped_up_balance":"19.15"}]}
        """)

        #expect(snapshot.isAvailable)
        #expect(snapshot.balances == [AccountBalance(currency: "CNY", total: Decimal(string: "19.15")!, granted: 0, toppedUp: Decimal(string: "19.15")!)])
    }

    @Test func parsesMultipleCurrencies() throws {
        let snapshot = try BalancePayloadParser.parse("""
        {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"19.15","granted_balance":"0.00","topped_up_balance":"19.15"},{"currency":"USD","total_balance":"2.50","granted_balance":"1.00","topped_up_balance":"1.50"}]}
        """)

        #expect(snapshot.balances.count == 2)
        #expect(snapshot.balances[1].currency == "USD")
        #expect(snapshot.balances[1].granted == Decimal(string: "1.00"))
    }

    @Test func rejectsMalformedMissingAndNegativeBalanceFields() {
        #expect(throws: Error.self) {
            try BalancePayloadParser.parse("{\"is_available\":true}")
        }
        #expect(throws: Error.self) {
            try BalancePayloadParser.parse("{\"is_available\":true,\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"-1\",\"granted_balance\":\"0\",\"topped_up_balance\":\"0\"}]}")
        }
        #expect(throws: Error.self) {
            try BalancePayloadParser.parse("not-json")
        }
    }

    @Test @MainActor func balanceFailureKeepsLastSuccessfulValueAsStale() async {
        let runner = StubBalanceRunner(output: availableBalanceJSON)
        let service = BalanceService(runner: runner, dshHome: URL(fileURLWithPath: "/tmp/dsh-home"))

        service.refresh()
        await waitForBalance(service)
        runner.setFailure(true)
        service.refresh()
        await waitForBalance(service)

        #expect(service.balances.first?.total == Decimal(string: "19.15"))
        #expect(service.isStale)
        #expect(service.errorMessage == "Balance unavailable. Please try again.")
    }

    @Test @MainActor func balanceRefreshDoesNotRunConcurrently() async {
        let runner = StubBalanceRunner(output: availableBalanceJSON, delay: 0.05)
        let service = BalanceService(runner: runner, dshHome: URL(fileURLWithPath: "/tmp/dsh-home"))

        service.refresh()
        service.refresh()
        await waitForBalance(service)

        #expect(runner.callCount == 1)
    }

    @Test func balanceErrorsNeverExposeSensitiveText() {
        let message = BalanceErrorSanitizer.message(for: SensitiveBalanceError())
        #expect(!message.localizedCaseInsensitiveContains("authorization"))
        #expect(!message.localizedCaseInsensitiveContains("api key"))
        #expect(!message.contains("secret-token"))
    }

    @Test func balanceCommandUsesManagedDSHHomeAndMinimalEnvironment() {
        let dshHome = URL(fileURLWithPath: "/tmp/managed-dsh-home")
        let command = BalanceCommand.managed(dshHome: dshHome)

        #expect(command.executable.path == "/bin/bash")
        #expect(command.arguments == ["/tmp/managed-dsh-home/skills/dsk-account-balance/scripts/check_balance.sh"])
        #expect(command.environment["DSH_HOME"] == "/tmp/managed-dsh-home")
        #expect(command.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(command.environment["DEEPSEEK_API_KEY"] == nil)
        #expect(command.environment["Authorization"] == nil)
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

private let availableBalanceJSON = """
{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"19.15","granted_balance":"0.00","topped_up_balance":"19.15"}]}
"""

@MainActor
private func waitForBalance(_ service: BalanceService) async {
    for _ in 0..<200 where service.isRefreshing {
        await Task.yield()
    }
}

private nonisolated final class StubBalanceRunner: BalanceRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var output: String
    private var fails = false
    private let delay: TimeInterval
    private var calls = 0

    nonisolated init(output: String, delay: TimeInterval = 0) {
        self.output = output
        self.delay = delay
    }

    nonisolated var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    nonisolated func setFailure(_ value: Bool) {
        lock.lock()
        fails = value
        lock.unlock()
    }

    nonisolated func run(_ command: BalanceCommand) throws -> BalanceProcessResult {
        lock.lock()
        calls += 1
        let shouldFail = fails
        let currentOutput = output
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if shouldFail { throw SensitiveBalanceError() }
        return BalanceProcessResult(status: 0, standardOutput: currentOutput, standardError: "")
    }
}

private nonisolated struct SensitiveBalanceError: LocalizedError {
    var errorDescription: String? { "Authorization: Bearer secret-token API Key" }
}

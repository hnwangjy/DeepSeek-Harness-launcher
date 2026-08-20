//
//  deepseek_launcherTests.swift
//  deepseek launcherTests
//
//  Created by wjy on 2026/8/14.
//

import Testing
import CryptoKit
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

    @Test func parsesRegistryMetadataForUpdatePackage() throws {
        let package = try UpdatePackageMetadataParser.parse(Data("""
        {"version":"0.1.0-rc.7","dist":{"tarball":"https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.0-rc.7.tgz","integrity":"sha512-c2lnbmF0dXJl","shasum":"aabbcc","unpackedSize":12600000}}
        """.utf8))

        #expect(package.version == "0.1.0-rc.7")
        #expect(package.tarballURL.lastPathComponent == "dsh-0.1.0-rc.7.tgz")
        #expect(package.integrity == "sha512-c2lnbmF0dXJl")
        #expect(package.shasum == "aabbcc")
        #expect(package.unpackedSize == 12_600_000)
    }

    @Test func downloadProgressSupportsKnownAndUnknownContentLength() {
        let known = UpdateDownloadState(downloadedBytes: 4_800_000, totalBytes: 12_600_000, bytesPerSecond: 2_100_000)
        let unknown = UpdateDownloadState(downloadedBytes: 4_800_000, totalBytes: nil, bytesPerSecond: nil)

        #expect(known.fractionCompleted == Double(4_800_000) / Double(12_600_000))
        #expect(unknown.fractionCompleted == nil)
        #expect(UpdateDisplayFormatter.speed(nil) == "正在连接…")
        #expect(UpdateDisplayFormatter.speed(2_100_000).hasSuffix("/s"))
    }

    @Test func movingAverageSpeedUsesBoundedMonotonicWindow() {
        var estimator = DownloadSpeedEstimator(window: 3)

        #expect(estimator.record(downloadedBytes: 0, uptime: 100) == nil)
        #expect(estimator.record(downloadedBytes: 3_000_000, uptime: 103) == 1_000_000)
        #expect(estimator.record(downloadedBytes: 7_000_000, uptime: 107) == nil)
    }

    @Test func verifiesSRIIntegrityAndRejectsMismatch() throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-integrity-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: archive) }
        let contents = Data("package archive fixture".utf8)
        try contents.write(to: archive)
        let digest = Data(SHA512.hash(data: contents)).base64EncodedString()
        let package = UpdatePackage(
            version: "1.0.0",
            tarballURL: URL(string: "https://example.invalid/dsh.tgz")!,
            integrity: "sha512-\(digest)",
            shasum: nil,
            unpackedSize: nil
        )

        try PackageIntegrityValidator.verify(archive: archive, package: package)
        let sha1 = Insecure.SHA1.hash(data: contents).map({ String(format: "%02x", $0) }).joined()
        let invalid = UpdatePackage(version: package.version, tarballURL: package.tarballURL, integrity: "sha512-cm9uZw==", shasum: sha1, unpackedSize: nil)
        #expect(throws: Error.self) {
            try PackageIntegrityValidator.verify(archive: archive, package: invalid)
        }
    }

    @Test func updateFlowRepresentsEveryUserVisiblePhase() {
        let package = updateFixturePackage
        let states: [HarnessUpdateFlow] = [
            .available(package),
            .downloading(UpdateDownloadState(downloadedBytes: 1, totalBytes: 2, bytesPerSecond: 1)),
            .verifying(package),
            .installing(package),
            .restarting(package),
            .ready(package.version)
        ]

        #expect(states.allSatisfy { $0 != .idle })
        #expect(HarnessUpdateFlow.downloading(UpdateDownloadState(downloadedBytes: 0, totalBytes: nil, bytesPerSecond: nil)).isInProgress)
        #expect(!HarnessUpdateFlow.ready(package.version).isInProgress)
    }

    @Test func updateOperationGatePreventsDuplicateUpdateAndTemporaryCleanupRemovesArchive() throws {
        let gate = UpdateOperationGate()
        #expect(gate.tryAcquire())
        #expect(!gate.tryAcquire())
        gate.release()
        #expect(gate.tryAcquire())

        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-cleanup-\(UUID().uuidString).tgz")
        try Data("temporary archive".utf8).write(to: archive)
        UpdateTemporaryFiles.remove(archive)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func localNPMInstallUsesOnlyTheDownloadedArchive() {
        let runtime = URL(fileURLWithPath: "/tmp/runtime")
        let prefix = URL(fileURLWithPath: "/tmp/harness")
        let archive = URL(fileURLWithPath: "/tmp/dsh-1.2.3.tgz")
        let command = LocalHarnessInstallCommand.make(runtime: runtime, prefix: prefix, archive: archive, environment: ["PATH": "/tmp/runtime/bin:/usr/bin:/bin"])

        #expect(command.executable.path == "/tmp/runtime/bin/npm")
        #expect(command.arguments == ["install", "--no-audit", "--no-fund", "--no-package-lock", "--prefix", "/tmp/harness", "/tmp/dsh-1.2.3.tgz"])
        #expect(!command.arguments.contains { $0.contains("@latest") })
    }

    @Test func appVersionInfoUsesBundleFieldsAndSafeFallbacks() {
        let complete = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ])
        let missing = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "  "
        ])

        #expect(complete.shortVersion == "1.0")
        #expect(complete.buildNumber == "1")
        #expect(complete.buildDisplay == "Build 1")
        #expect(missing.shortVersion == "未知版本")
        #expect(missing.buildNumber == "未知构建")
    }

    @Test @MainActor func versionCopyTextAndHarnessDisplayMapping() {
        let appVersion = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ])
        let installed = HarnessVersionDisplay.resolve(installedVersion: "0.1.0-rc.7", status: .ready)
        let notInstalled = HarnessVersionDisplay.resolve(installedVersion: nil, status: .stopped)
        let detecting = HarnessVersionDisplay.resolve(installedVersion: nil, status: .starting)
        let unavailable = HarnessVersionDisplay.resolve(installedVersion: nil, status: .failed("error"))

        #expect(appVersion.copyText(harness: installed) == "DeepSeek Harness Launcher 1.0 (1)\nDeepSeek Harness 0.1.0-rc.7")
        #expect(installed.text == "0.1.0-rc.7")
        #expect(notInstalled.text == "尚未安装")
        #expect(detecting.text == "正在检测…")
        #expect(unavailable.text == "无法读取")
    }

    @Test func updateToolbarPresentationKeepsOneStableButtonAcrossStates() {
        let idle = UpdateToolbarPresentation.make(isChecking: false, isAvailable: false, isUpdating: false)
        let checking = UpdateToolbarPresentation.make(isChecking: true, isAvailable: false, isUpdating: false)
        let available = UpdateToolbarPresentation.make(isChecking: false, isAvailable: true, isUpdating: false)
        let updating = UpdateToolbarPresentation.make(isChecking: false, isAvailable: true, isUpdating: true)

        #expect(idle.symbol == "arrow.triangle.2.circlepath")
        #expect(!idle.showsProgress && !idle.isDisabled)
        #expect(checking.showsProgress && checking.isDisabled)
        #expect(checking.accessibilityValue == "正在检查")
        #expect(available.symbol == "arrow.triangle.2.circlepath")
        #expect(available.accessibilityValue == "有可用更新")
        #expect(updating.showsProgress && updating.isDisabled)
        #expect(updating.accessibilityValue == "正在更新")
        #expect(Set([idle.visualSlotPoints, checking.visualSlotPoints, available.visualSlotPoints, updating.visualSlotPoints]) == Set([16]))
    }

    @Test func taskNotificationParserUsesTheRealServerRequestPayloadEnvelope() throws {
        let frame = try HarnessMuxFrameParser.parse("""
        {"type":"server-request","rpcId":"rpc-1","method":"events.mux","payload":{"type":"session/event","sessionId":"session-1","event":{"seq":4,"time":1,"type":"turn/start","data":{"turn":7}}}}
        """)

        guard case let .event(sessionID, sequence, type, data) = frame else {
            Issue.record("The mux payload should parse as a session event.")
            return
        }
        #expect(sessionID == "session-1")
        #expect(sequence == 4)
        #expect(type == "turn/start")
        #expect(data["turn"] as? Int == 7)
    }

    @Test func taskNotificationWebSocketURLExplicitlyConvertsHTTPAndHTTPS() {
        #expect(HarnessEventURLBuilder.make(serverURL: URL(string: "http://127.0.0.1:3080")!) == URL(string: "ws://127.0.0.1:3080/api/events.mux")!)
        #expect(HarnessEventURLBuilder.make(serverURL: URL(string: "https://example.test/harness")!) == URL(string: "wss://example.test/harness/api/events.mux")!)
        #expect(HarnessEventURLBuilder.make(serverURL: URL(string: "ftp://example.test")!) == nil)
    }

    @Test func persistedNotificationOptInCanResumeOnlyAfterAuthorizationAndReady() {
        #expect(TaskNotificationConnectionPolicy.shouldConnect(isEnabled: true, authorization: .authorized, harnessIsReady: true))
        #expect(!TaskNotificationConnectionPolicy.shouldConnect(isEnabled: true, authorization: .notDetermined, harnessIsReady: true))
        #expect(!TaskNotificationConnectionPolicy.shouldConnect(isEnabled: true, authorization: .authorized, harnessIsReady: false))
        #expect(!TaskNotificationConnectionPolicy.shouldConnect(isEnabled: false, authorization: .authorized, harnessIsReady: true))
    }

    @Test func taskNotificationEngineSendsOneCompletionAndOneErrorPerTurn() {
        var engine = TaskNotificationEngine()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        #expect(engine.consume(taskEvent(sequence: 1, type: "turn/start", turn: 3), now: now).isEmpty)
        let completion = engine.consume(taskEvent(sequence: 2, type: "turn/end", turn: 3), now: now)
        #expect(completion == [TaskNotificationEvent(sessionID: "session", turn: 3, kind: .completed, body: "本轮任务已完成。")])
        #expect(engine.consume(taskEvent(sequence: 3, type: "turn/end", turn: 3), now: now).isEmpty)

        #expect(engine.consume(taskEvent(sequence: 4, type: "turn/start", turn: 4), now: now).isEmpty)
        let failure = engine.consume(taskEvent(sequence: 5, type: "turn/end", turn: 4, errorMessage: "Bearer secret-token"), now: now)
        #expect(failure.first?.kind == .failed)
        #expect(!failure.first!.body.localizedCaseInsensitiveContains("bearer"))
        #expect(!failure.first!.body.contains("secret-token"))
    }

    @Test func taskNotificationEngineDetectsStallOnceAndAllowsARecoveredTurnToStallAgain() {
        var engine = TaskNotificationEngine()
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        _ = engine.consume(taskEvent(sequence: 1, type: "turn/start", turn: 9), now: start)

        let firstStall = engine.stalledEvents(threshold: 300, now: start.addingTimeInterval(300))
        #expect(firstStall.map(\.kind) == [.stuck])
        #expect(engine.stalledEvents(threshold: 300, now: start.addingTimeInterval(301)).isEmpty)

        _ = engine.consume(taskEvent(sequence: 2, type: "assistant/message", turn: nil), now: start.addingTimeInterval(302))
        let secondStall = engine.stalledEvents(threshold: 300, now: start.addingTimeInterval(602))
        #expect(secondStall.map(\.kind) == [.stuck])
    }

    @Test func taskNotificationEngineDoesNotReplayHistoricalCompletionAfterReconnect() {
        var engine = TaskNotificationEngine()
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        _ = engine.consume(.subscribed(sessionID: "session", lastSequence: 10), now: now)
        #expect(engine.consume(taskEvent(sequence: 10, type: "turn/end", turn: 1), now: now).isEmpty)

        _ = engine.consume(taskEvent(sequence: 11, type: "turn/start", turn: 2), now: now)
        #expect(engine.consume(taskEvent(sequence: 12, type: "turn/end", turn: 2), now: now).map(\.kind) == [.completed])

        _ = engine.consume(.subscribed(sessionID: "session", lastSequence: 12), now: now)
        #expect(engine.consume(taskEvent(sequence: 12, type: "turn/end", turn: 2), now: now).isEmpty)
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

private let updateFixturePackage = UpdatePackage(
    version: "0.1.0-rc.7",
    tarballURL: URL(string: "https://example.invalid/dsh.tgz")!,
    integrity: "sha512-c2lnbmF0dXJl",
    shasum: nil,
    unpackedSize: 12_600_000
)

private func taskEvent(sequence: Int, type: String, turn: Int?, errorMessage: String? = nil) -> HarnessMuxFrameParser.Frame {
    var data: [String: Any] = [:]
    if let turn { data["turn"] = turn }
    if type == "turn/end" {
        if let errorMessage {
            data["reason"] = ["kind": "error", "message": errorMessage]
        } else {
            data["reason"] = ["kind": "completed"]
        }
    }
    return .event(sessionID: "session", sequence: sequence, type: type, data: data)
}

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

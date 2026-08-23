//
//  ContentView.swift
//  deepseek launcher
//

import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

@MainActor
final class HarnessService: ObservableObject {
    static let shared = HarnessService()

    enum Status: Equatable {
        case stopped
        case installingRuntime
        case installingHarness
        case starting
        case updating
        case ready
        case failed(String)
    }

    enum UpdateCheckState: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdatePackage)
        case failed
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var installedVersion: String?
    @Published private(set) var updateAvailable = false
    @Published private(set) var updateCheckState: UpdateCheckState = .idle
    @Published private(set) var updateFlow: HarnessUpdateFlow = .idle
    @Published private(set) var isManualUpdateCheck = false
    @Published private(set) var progressStep = 0
    @Published private(set) var progressDetail = ""
    @Published private(set) var reloadID = UUID()

    let serverURL = URL(string: "http://127.0.0.1:3080")!
    let taskNotifications = TaskNotificationService.shared

    private let nodeVersion = "24.18.0"
    private let nodeArchiveSHA256 = "e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
    private let registryClient: any PackageMetadataFetching = NPMRegistryClient()
    private let packageDownloader: any PackageDownloading = URLSessionPackageDownloader()
    private let updateOperationGate = UpdateOperationGate()
    private var process: Process?
    private var isBusy = false

    let progressStepCount = 3
    var progressFraction: Double {
        Double(progressStep) / Double(progressStepCount)
    }

    var isCheckingForUpdate: Bool {
        updateCheckState == .checking
    }

    var isUpdatingHarness: Bool {
        updateFlow.isInProgress && updateFlow != .checking
    }

    private init() {}

    func start() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                let paths = try makePaths()
                if await serverIsReachable() {
                    installedVersion = localHarnessVersion(paths)
                    finishAsReady(paths)
                    return
                }
                try await prepareAndLaunch(paths)
            } catch {
                finishWithError(error)
            }
        }
    }

    func restart() {
        guard !isBusy else { return }
        isBusy = true
        stopProcessOnly()
        taskNotifications.harnessDidBecomeUnavailable()
        status = .starting
        setProgress(step: 1, detail: "Preparing the local runtime")
        Task {
            await waitForServerToStop()
            do {
                let paths = try makePaths()
                try await prepareAndLaunch(paths)
            } catch {
                finishWithError(error)
            }
        }
    }

    func updateHarness() {
        guard !isBusy,
              case let .available(package) = updateCheckState,
              updateOperationGate.tryAcquire() else { return }
        isBusy = true
        updateAvailable = false
        Task {
            defer { updateOperationGate.release() }
            do {
                let paths = try makePaths()
                try await updateHarness(paths, package: package)
            } catch {
                finishUpdateFailure(error)
            }
        }
    }

    func checkForUpdateManually() {
        guard !isCheckingForUpdate, !isBusy else { return }
        isManualUpdateCheck = true
        Task {
            do {
                let paths = try makePaths()
                await checkForUpdate(paths)
            } catch {
                updateCheckState = .failed
            }
        }
    }

    func dismissManualUpdateCheck() {
        isManualUpdateCheck = false
    }

    func stop() {
        stopProcessOnly()
        taskNotifications.harnessDidBecomeUnavailable()
        isBusy = false
        status = .stopped
    }

    private func prepareAndLaunch(_ paths: Paths) async throws {
        status = .installingRuntime
        setProgress(step: 1, detail: "Preparing the local runtime")
        try await installManagedNodeIfNeeded(paths)

        status = .installingHarness
        setProgress(step: 2, detail: "Downloading DeepSeek Harness")
        try await installHarness(paths)
        installedVersion = localHarnessVersion(paths)

        status = .starting
        setProgress(step: 3, detail: "Starting and verifying the local service")
        try launchHarness(paths)
        try await waitForServer()
        finishAsReady(paths)
    }

    private func finishAsReady(_ paths: Paths) {
        isBusy = false
        status = .ready
        progressStep = progressStepCount
        progressDetail = "Ready"
        reloadID = UUID()
        taskNotifications.harnessDidBecomeReady(serverURL: serverURL)
        Task { await checkForUpdate(paths) }
    }

    private func finishWithError(_ error: Error) {
        stopProcessOnly()
        taskNotifications.harnessDidBecomeUnavailable()
        isBusy = false
        progressStep = 0
        progressDetail = ""
        status = .failed(error.localizedDescription)
    }

    private func setProgress(step: Int, detail: String) {
        progressStep = step
        progressDetail = detail
    }

    private func makePaths() throws -> Paths {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("DeepSeek Harness", isDirectory: true)
        let paths = Paths(
            root: root,
            runtime: root.appendingPathComponent("runtime", isDirectory: true),
            harness: root.appendingPathComponent("harness", isDirectory: true),
            dshHome: root.appendingPathComponent("dsh-home", isDirectory: true),
            workspace: root.appendingPathComponent("workspace", isDirectory: true),
            log: root.appendingPathComponent("harness.log")
        )
        try FileManager.default.createDirectory(at: paths.dshHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.workspace, withIntermediateDirectories: true)
        return paths
    }

    private func installManagedNodeIfNeeded(_ paths: Paths) async throws {
        let node = paths.runtime.appendingPathComponent("bin/node")
        if FileManager.default.isExecutableFile(atPath: node.path) {
            let result = try await runProcess(node.path, arguments: ["--version"])
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("v24.") { return }
        }

        let archiveURL = URL(string: "https://nodejs.org/dist/v\(nodeVersion)/node-v\(nodeVersion)-darwin-arm64.tar.gz")!
        let (downloadedURL, response) = try await URLSession.shared.download(from: archiveURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LauncherError.runtimeDownloadFailed
        }
        let checksum = try await runProcess("/usr/bin/shasum", arguments: ["-a", "256", downloadedURL.path])
        guard checksum.output.lowercased().hasPrefix(nodeArchiveSHA256) else {
            throw LauncherError.runtimeIntegrityFailed
        }

        let fileManager = FileManager.default
        let staging = paths.root.appendingPathComponent("runtime-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            _ = try await runProcess("/usr/bin/tar", arguments: ["-xzf", downloadedURL.path, "-C", staging.path, "--strip-components=1"])
            guard fileManager.isExecutableFile(atPath: staging.appendingPathComponent("bin/node").path) else {
                throw LauncherError.runtimeDownloadFailed
            }
            if fileManager.fileExists(atPath: paths.runtime.path) {
                try fileManager.removeItem(at: paths.runtime)
            }
            try fileManager.moveItem(at: staging, to: paths.runtime)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func installHarness(_ paths: Paths) async throws {
        let dsh = paths.harness.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
        guard !FileManager.default.fileExists(atPath: dsh.path) else { return }
        let package = try await registryClient.fetchLatestPackage()
        let archive = try await downloadPackage(package, paths: paths, reportProgress: false)
        defer { removeUpdateArchive(archive) }
        try await verifyPackage(archive, package: package)
        try await installHarnessArchive(archive, prefix: paths.harness, paths: paths)
    }

    private func updateHarness(_ paths: Paths, package: UpdatePackage) async throws {
        // Keep the working service online until the archive has been downloaded
        // and verified. A network or integrity failure therefore cannot disrupt
        // an existing workspace.
        updateFlow = .downloading(UpdateDownloadState(downloadedBytes: 0, totalBytes: nil, bytesPerSecond: nil))
        let archive = try await downloadPackage(package, paths: paths, reportProgress: true)
        defer { removeUpdateArchive(archive) }

        updateFlow = .verifying(package)
        try await verifyPackage(archive, package: package)

        updateFlow = .installing(package)
        let staging = paths.root.appendingPathComponent("harness-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await installHarnessArchive(archive, prefix: staging, paths: paths)

        updateFlow = .restarting(package)
        stopProcessOnly()
        taskNotifications.harnessDidBecomeUnavailable()
        await waitForServerToStop()
        let backup = try replaceHarness(with: staging, paths: paths)
        status = .starting
        do {
            try launchHarness(paths)
            try await waitForServer()
        } catch {
            stopProcessOnly()
            restoreHarnessBackup(backup, paths: paths)
            if backup != nil {
                try? launchHarness(paths)
                try? await waitForServer()
                status = .ready
                reloadID = UUID()
                taskNotifications.harnessDidBecomeReady(serverURL: serverURL)
            }
            throw error
        }
        if let backup { try? FileManager.default.removeItem(at: backup) }
        isBusy = false
        status = .ready
        installedVersion = localHarnessVersion(paths)
        progressStep = progressStepCount
        progressDetail = "Ready"
        reloadID = UUID()
        updateFlow = .ready(package.version)
        taskNotifications.harnessDidBecomeReady(serverURL: serverURL)
        Task { await checkForUpdate(paths) }
    }

    private func downloadPackage(_ package: UpdatePackage, paths: Paths, reportProgress: Bool) async throws -> URL {
        let temporaryDirectory = paths.root.appendingPathComponent("updates", isDirectory: true)
        let stateBox = DownloadStateBox()
        return try await packageDownloader.download(package, to: temporaryDirectory) { [weak self] sample in
            guard reportProgress else { return }
            let speed = stateBox.record(sample)
            Task { @MainActor in
                self?.updateFlow = .downloading(UpdateDownloadState(
                    downloadedBytes: sample.downloadedBytes,
                    totalBytes: sample.expectedBytes,
                    bytesPerSecond: speed
                ))
            }
        }
    }

    private func verifyPackage(_ archive: URL, package: UpdatePackage) async throws {
        try await Task.detached(priority: .userInitiated) {
            try PackageIntegrityValidator.verify(archive: archive, package: package)
        }.value
    }

    private func installHarnessArchive(_ archive: URL, prefix: URL, paths: Paths) async throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let dsh = prefix.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
        let command = LocalHarnessInstallCommand.make(
            runtime: paths.runtime,
            prefix: prefix,
            archive: archive,
            environment: runtimeEnvironment(paths)
        )
        let result = try await runProcess(
            command.executable.path,
            arguments: command.arguments,
            environment: command.environment
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: dsh.path) else {
            throw UpdateSupportError.installFailed
        }
    }

    private func removeUpdateArchive(_ archive: URL) {
        UpdateTemporaryFiles.remove(archive)
    }

    private func replaceHarness(with staging: URL, paths: Paths) throws -> URL? {
        let fileManager = FileManager.default
        let backup = paths.root.appendingPathComponent("harness-backup-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: paths.harness.path) {
            try fileManager.moveItem(at: paths.harness, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: paths.harness)
            return fileManager.fileExists(atPath: backup.path) ? backup : nil
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: paths.harness)
            }
            throw error
        }
    }

    private func restoreHarnessBackup(_ backup: URL?, paths: Paths) {
        guard let backup else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: paths.harness)
        try? fileManager.moveItem(at: backup, to: paths.harness)
    }

    private func launchHarness(_ paths: Paths) throws {
        let dsh = paths.harness.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
        let node = paths.runtime.appendingPathComponent("bin/node")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: dsh.path) else {
            throw LauncherError.harnessMissing
        }

        FileManager.default.createFile(atPath: paths.log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: paths.log)
        try logHandle.seekToEnd()
        let launched = Process()
        launched.executableURL = node
        launched.arguments = [dsh.path, "web", "--host", "127.0.0.1", "--port", "3080"]
        launched.currentDirectoryURL = paths.workspace
        launched.environment = runtimeEnvironment(paths, extra: ["DSH_HOME": paths.dshHome.path])
        launched.standardOutput = logHandle
        launched.standardError = logHandle
        launched.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                guard self?.process === process, self?.isBusy == true else { return }
                self?.finishWithError(LauncherError.harnessExited(process.terminationStatus))
            }
        }
        process = launched
        try launched.run()
    }

    private func checkForUpdate(_ paths: Paths) async {
        guard let installedVersion else {
            updateCheckState = .idle
            return
        }
        updateCheckState = .checking
        updateFlow = .checking
        guard let package = try? await registryClient.fetchLatestPackage() else {
            updateCheckState = .failed
            updateFlow = .failed(UpdateSupportError.registryUnavailable.localizedDescription)
            return
        }
        updateAvailable = package.version != installedVersion
        updateCheckState = updateAvailable ? .available(package) : .upToDate
        updateFlow = updateAvailable ? .available(package) : .upToDate
    }

    private func localHarnessVersion(_ paths: Paths) -> String? {
        let package = paths.harness.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        guard let data = try? Data(contentsOf: package),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["version"] as? String
    }

    private func runtimeEnvironment(_ paths: Paths, extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "HOME": paths.root.path,
            "PATH": "\(paths.runtime.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        extra.forEach { environment[$0.key] = $0.value }
        return environment
    }

    private func finishUpdateFailure(_ error: Error) {
        // Download and verification happen before stopping the service. Keep a
        // usable workspace available whenever a package update fails there.
        isBusy = false
        let message = sanitizedUpdateError(error)
        if case .starting = status { status = .failed(message) }
        updateFlow = .failed(message)
    }

    private func sanitizedUpdateError(_ error: Error) -> String {
        if let supportError = error as? UpdateSupportError {
            return supportError.localizedDescription
        }
        return "更新未完成，请稍后重试。"
    }

    private func stopProcessOnly() {
        process?.terminate()
        process = nil
    }

    private func serverIsReachable() async -> Bool {
        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 500) < 500
        } catch {
            return false
        }
    }

    private func waitForServer() async throws {
        for _ in 0..<120 {
            if await serverIsReachable() { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw LauncherError.startupTimedOut
    }

    private func waitForServerToStop() async {
        for _ in 0..<30 {
            guard await serverIsReachable() else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func runProcess(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, arguments: arguments, environment: environment)
    }
}

nonisolated enum ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let pipe = Pipe()
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.environment = environment
        command.standardOutput = pipe
        command.standardError = pipe
        try command.run()
        // Drain the pipe while the child is running. Waiting until termination
        // before reading can deadlock verbose commands such as npm install once
        // the kernel pipe buffer fills up.
        try? pipe.fileHandleForWriting.close()
        let outputData = await Task.detached(priority: .utility) {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        command.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return ProcessResult(status: command.terminationStatus, output: output)
    }
}

private struct Paths {
    let root: URL
    let runtime: URL
    let harness: URL
    let dshHome: URL
    let workspace: URL
    let log: URL
}

nonisolated struct ProcessResult: Sendable {
    let status: Int32
    let output: String
}

private enum LauncherError: LocalizedError {
    case runtimeDownloadFailed
    case runtimeIntegrityFailed
    case harnessMissing
    case harnessExited(Int32)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .runtimeDownloadFailed:
            return "The bundled Node.js runtime could not be downloaded. Check your internet connection and try again."
        case .runtimeIntegrityFailed:
            return "The downloaded Node.js runtime failed its integrity check."
        case .harnessMissing:
            return "DeepSeek Harness is not installed."
        case let .harnessExited(code):
            return "DeepSeek Harness exited unexpectedly (code \(code))."
        case .startupTimedOut:
            return "Harness did not start within two minutes. Open the log file in Application Support for details."
        }
    }
}

struct ContentView: View {
    private enum UpdatePanel: Equatable {
        case available(UpdatePackage)
        case progress
        case failed(String)
    }

    private struct Toast: Equatable {
        let message: String
        let symbol: String
    }

    @ObservedObject var harness: HarnessService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var balance = BalanceService()
    @StateObject private var taskNotifications = TaskNotificationService.shared
    @State private var updatePanel: UpdatePanel?
    @State private var toast: Toast?
    @State private var showsPluginManager = false
    @State private var showsBalance = false
    @State private var showsTaskNotifications = false

    var body: some View {
        Group {
            if case .ready = harness.status {
                HarnessWebView(url: harness.serverURL, reloadID: harness.reloadID)
            } else {
                launchView
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .toolbar {
            if case .ready = harness.status {
                ToolbarItem(placement: .automatic) {
                    balanceButton
                }
                ToolbarItem(placement: .automatic) {
                    taskNotificationButton
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { showsPluginManager = true }) {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
                    }
                    .help("Manage plugins")
                    updateToolbarButton
                    Button(action: openInBrowser) {
                        Label("Open in Browser", systemImage: "safari")
                    }
                }
            }
        }
        .sheet(isPresented: $showsPluginManager) {
            PluginManagementView(onInstallationSucceeded: { harness.restart() })
        }
        .overlay(alignment: .top) {
            if harness.isManualUpdateCheck && harness.isCheckingForUpdate {
                toastView(Toast(message: "正在检查更新…", symbol: "arrow.triangle.2.circlepath"))
                    .padding(.top, 18)
            } else if let toast {
                toastView(toast)
                    .padding(.top, 18)
            }
        }
        .overlay {
            if let updatePanel {
                updatePanelView(updatePanel)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.24), value: updatePanel)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.24), value: toast)
        .onChange(of: harness.updateCheckState) { _, state in
            handleManualUpdateCheck(state)
        }
        .onChange(of: harness.status) { _, state in
            handleUpdateCompletion(state)
            updateBalancePolling()
        }
        .onChange(of: harness.updateFlow) { _, flow in
            if case let .failed(message) = flow, updatePanel == .progress {
                updatePanel = .failed(message)
            }
        }
        .onChange(of: scenePhase) { _, _ in
            updateBalancePolling()
            taskNotifications.setAppIsActive(scenePhase == .active)
        }
        .task {
            harness.start()
            updateBalancePolling()
            taskNotifications.setAppIsActive(scenePhase == .active)
        }
    }

    private var balanceButton: some View {
        Button(action: { showsBalance.toggle() }) {
            HStack(spacing: 6) {
                if balance.isRefreshing && !balance.hasHistoricalBalance {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "creditcard")
                }
                Text(balanceToolbarTitle)
                if balance.isStale { Image(systemName: "exclamationmark.triangle.fill") }
            }
        }
        .buttonStyle(.bordered)
        .help("View account balance")
        .accessibilityLabel("Account balance: \(balanceToolbarTitle)")
        .popover(isPresented: $showsBalance, arrowEdge: .bottom) {
            BalancePopoverView(balance: balance)
        }
    }

    private var balanceToolbarTitle: String {
        guard let primaryBalance = balance.primaryBalance else { return "Balance unavailable" }
        return BalanceFormatter.amount(primaryBalance.total, currency: primaryBalance.currency)
    }

    private var taskNotificationButton: some View {
        Button(action: { showsTaskNotifications.toggle() }) {
            Image(systemName: taskNotifications.preferences.isEnabled ? "bell.fill" : "bell")
                .frame(width: 16, height: 16)
        }
        .help("任务通知设置")
        .accessibilityLabel(taskNotifications.preferences.isEnabled ? "任务通知，已启用" : "任务通知，未启用")
        .popover(isPresented: $showsTaskNotifications, arrowEdge: .bottom) {
            TaskNotificationPopoverView(notifications: taskNotifications)
        }
    }

    private var updateToolbarPresentation: UpdateToolbarPresentation {
        UpdateToolbarPresentation.make(
            isChecking: harness.isCheckingForUpdate,
            isAvailable: harness.updateAvailable,
            isUpdating: harness.isUpdatingHarness
        )
    }

    private var updateToolbarButton: some View {
        let presentation = updateToolbarPresentation
        return Button(action: { harness.checkForUpdateManually() }) {
            ZStack {
                Image(systemName: presentation.symbol)
                    .opacity(presentation.showsProgress ? 0 : 1)
                    .accessibilityHidden(true)
                ProgressView()
                    .controlSize(.small)
                    .opacity(presentation.showsProgress ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(width: CGFloat(presentation.visualSlotPoints), height: CGFloat(presentation.visualSlotPoints))
        }
        .disabled(presentation.isDisabled)
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    private func updateBalancePolling() {
        let harnessIsReady: Bool
        if case .ready = harness.status {
            harnessIsReady = true
        } else {
            harnessIsReady = false
        }
        balance.setPolling(isActive: harnessIsReady && scenePhase == .active)
    }

    @ViewBuilder
    private func updatePanelView(_ panel: UpdatePanel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            switch panel {
            case let .available(package):
                updateCardHeader(
                    title: "发现新版本",
                    subtitle: "DeepSeek Harness",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .accentColor
                )
                Text("v\(package.version)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("新版本 v\(package.version)")
                Text("更新完成后将自动重启本地服务并刷新工作区。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("稍后") { updatePanel = nil }
                    Button("立即更新") {
                        updatePanel = .progress
                        harness.updateHarness()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .progress:
                updateProgressContent
            case let .failed(message):
                updateCardHeader(
                    title: "更新未完成",
                    subtitle: "DeepSeek Harness",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("更新失败：\(message)")
                HStack {
                    Spacer()
                    Button("关闭") { updatePanel = nil }
                    Button("重试") {
                        guard case let .available(package) = harness.updateCheckState else {
                            harness.checkForUpdateManually()
                            return
                        }
                        updatePanel = .available(package)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.primary.opacity(reduceTransparency ? 0.16 : 0.08))
        }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        .transition(.opacity)
    }

    private func updateCardHeader(title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(subtitle)")
    }

    @ViewBuilder
    private var updateProgressContent: some View {
        updateCardHeader(
            title: "正在更新",
            subtitle: "DeepSeek Harness",
            symbol: "arrow.triangle.2.circlepath",
            tint: .accentColor
        )

        switch harness.updateFlow {
        case let .downloading(download):
            Text("正在下载更新包")
                .font(.subheadline.weight(.medium))
            if let fraction = download.fractionCompleted {
                ProgressView(value: fraction)
                    .accessibilityLabel("更新包下载进度")
                    .accessibilityValue("\(Int((fraction * 100).rounded()))%")
                HStack {
                    Text(downloadDescription(download))
                    Spacer()
                    Text(UpdateDisplayFormatter.speed(download.bytesPerSecond))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("下载百分比 \(Int((fraction * 100).rounded()))%")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在下载更新包")
                HStack {
                    Text(downloadDescription(download))
                    Spacer()
                    Text(UpdateDisplayFormatter.speed(download.bytesPerSecond))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .verifying:
            indeterminateUpdatePhase("正在校验更新包", detail: "正在验证发布方提供的完整性信息。")
        case .installing:
            indeterminateUpdatePhase("正在安装依赖", detail: "依赖解析和安装不提供可靠的字节进度。")
        case .restarting:
            indeterminateUpdatePhase("正在重启本地服务", detail: "完成后将自动刷新工作区。")
        default:
            indeterminateUpdatePhase("正在准备更新", detail: "请保持此窗口打开。")
        }

        Text("仅主更新包显示真实下载字节；依赖安装阶段不估算下载速度。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("仅主更新包显示真实下载字节，依赖安装阶段不估算下载速度")
    }

    private func indeterminateUpdatePhase(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.medium))
            ProgressView().controlSize(.small).accessibilityLabel(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func downloadDescription(_ download: UpdateDownloadState) -> String {
        let downloaded = UpdateDisplayFormatter.byteCount(download.downloadedBytes)
        guard let total = download.totalBytes else { return "已下载 \(downloaded)" }
        return "已下载 \(downloaded) / \(UpdateDisplayFormatter.byteCount(total))"
    }

    private func toastView(_ toast: Toast) -> some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var launchView: some View {
        VStack(spacing: 16) {
            Image(systemName: statusIcon)
                .font(.system(size: 42))
                .foregroundStyle(statusColor)
            Text(statusTitle)
                .font(.title2.weight(.semibold))
            Text(statusMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            if isWorking {
                VStack(spacing: 8) {
                    ProgressView(value: harness.progressFraction)
                        .frame(width: 300)
                    Text("Step \(harness.progressStep) of \(harness.progressStepCount) · \(harness.progressDetail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Installation progress: step \(harness.progressStep) of \(harness.progressStepCount). \(harness.progressDetail)")
                }
                .padding(.top, 4)
            }
            if case .failed = harness.status {
                Button("Try Again") { harness.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    private var isWorking: Bool {
        switch harness.status {
        case .installingRuntime, .installingHarness, .starting, .updating: return true
        default: return false
        }
    }

    private var statusIcon: String {
        if case .failed = harness.status { return "exclamationmark.triangle" }
        return "sparkles"
    }

    private var statusColor: Color {
        if case .failed = harness.status { return .orange }
        return .accentColor
    }

    private var statusTitle: String {
        switch harness.status {
        case .installingRuntime: return "Preparing a compatible runtime"
        case .installingHarness: return "Installing DeepSeek Harness"
        case .starting: return "Starting DeepSeek Harness"
        case .updating: return "Updating DeepSeek Harness"
        case .failed: return "Harness couldn't start"
        case .stopped, .ready: return "DeepSeek Harness"
        }
    }

    private var statusMessage: String {
        switch harness.status {
        case .installingRuntime:
            return "Downloading the local Node.js runtime. This is needed only once."
        case .installingHarness:
            return "Downloading DeepSeek Harness. The first launch can take a few minutes."
        case .starting:
            return "Opening your local coding workspace."
        case .updating:
            return "Installing the newest DeepSeek Harness release, then restarting it."
        case let .failed(message):
            return message
        case .stopped:
            return "Start your local coding agent."
        case .ready:
            return ""
        }
    }

    private func handleManualUpdateCheck(_ state: HarnessService.UpdateCheckState) {
        guard harness.isManualUpdateCheck else { return }
        switch state {
        case .checking, .idle:
            return
        case let .available(package):
            harness.dismissManualUpdateCheck()
            updatePanel = .available(package)
        case .upToDate:
            harness.dismissManualUpdateCheck()
            showToast("DeepSeek Harness 已是最新版本。", symbol: "checkmark.circle.fill")
        case .failed:
            harness.dismissManualUpdateCheck()
            showToast("检查更新失败，请稍后重试。", symbol: "exclamationmark.triangle.fill")
        }
    }

    private func handleUpdateCompletion(_ state: HarnessService.Status) {
        guard updatePanel == .progress else { return }
        switch state {
        case .ready:
            if case .ready = harness.updateFlow {
                updatePanel = nil
                showToast("更新完成，工作区已刷新。", symbol: "checkmark.circle.fill")
            }
        case .failed:
            updatePanel = .failed("更新未完成，请稍后重试。")
        default:
            return
        }
    }

    private func showToast(_ message: String, symbol: String) {
        let nextToast = Toast(message: message, symbol: symbol)
        toast = nextToast
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard toast == nextToast else { return }
            toast = nil
        }
    }

    private func openInBrowser() {
        NSWorkspace.shared.open(harness.serverURL)
    }
}

private struct HarnessWebView: NSViewRepresentable {
    let url: URL
    let reloadID: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        context.coordinator.reloadID = reloadID
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.reloadID != reloadID else { return }
        context.coordinator.reloadID = reloadID
        webView.load(URLRequest(url: url))
    }

    final class Coordinator {
        var reloadID: UUID?
    }
}

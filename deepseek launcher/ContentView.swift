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

    @Published private(set) var status: Status = .stopped
    @Published private(set) var installedVersion: String?
    @Published private(set) var updateAvailable = false
    @Published private(set) var reloadID = UUID()

    let serverURL = URL(string: "http://127.0.0.1:3080")!

    private let nodeVersion = "24.18.0"
    private let nodeArchiveSHA256 = "e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
    private var process: Process?
    private var isBusy = false

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
                try await prepareAndLaunch(paths, update: false)
            } catch {
                finishWithError(error)
            }
        }
    }

    func restart() {
        guard !isBusy else { return }
        isBusy = true
        stopProcessOnly()
        status = .starting
        Task {
            await waitForServerToStop()
            do {
                let paths = try makePaths()
                try await prepareAndLaunch(paths, update: false)
            } catch {
                finishWithError(error)
            }
        }
    }

    func updateHarness() {
        guard !isBusy else { return }
        isBusy = true
        updateAvailable = false
        Task {
            do {
                let paths = try makePaths()
                stopProcessOnly()
                await waitForServerToStop()
                try await prepareAndLaunch(paths, update: true)
            } catch {
                finishWithError(error)
            }
        }
    }

    func stop() {
        stopProcessOnly()
        isBusy = false
        status = .stopped
    }

    private func prepareAndLaunch(_ paths: Paths, update: Bool) async throws {
        status = .installingRuntime
        try await installManagedNodeIfNeeded(paths)

        status = update ? .updating : .installingHarness
        try await installHarness(paths, forceUpdate: update)
        installedVersion = localHarnessVersion(paths)

        status = .starting
        try launchHarness(paths)
        try await waitForServer()
        finishAsReady(paths)
    }

    private func finishAsReady(_ paths: Paths) {
        isBusy = false
        status = .ready
        reloadID = UUID()
        Task { await checkForUpdate(paths) }
    }

    private func finishWithError(_ error: Error) {
        stopProcessOnly()
        isBusy = false
        status = .failed(error.localizedDescription)
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

    private func installHarness(_ paths: Paths, forceUpdate: Bool) async throws {
        let dsh = paths.harness.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
        guard forceUpdate || !FileManager.default.fileExists(atPath: dsh.path) else { return }
        try FileManager.default.createDirectory(at: paths.harness, withIntermediateDirectories: true)
        let npm = paths.runtime.appendingPathComponent("bin/npm")
        let result = try await runProcess(
            npm.path,
            arguments: ["install", "--no-audit", "--no-fund", "--no-package-lock", "--prefix", paths.harness.path, "@deepseek-ai/dsh@latest"],
            environment: runtimeEnvironment(paths)
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: dsh.path) else {
            throw LauncherError.harnessInstallFailed(result.output)
        }
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
                guard self?.isBusy == true else { return }
                self?.finishWithError(LauncherError.harnessExited(process.terminationStatus))
            }
        }
        process = launched
        try launched.run()
    }

    private func checkForUpdate(_ paths: Paths) async {
        guard let installedVersion else { return }
        let npm = paths.runtime.appendingPathComponent("bin/npm")
        guard FileManager.default.isExecutableFile(atPath: npm.path),
              let result = try? await runProcess(npm.path, arguments: ["view", "@deepseek-ai/dsh", "version"], environment: runtimeEnvironment(paths)),
              result.status == 0 else { return }
        let latest = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        updateAvailable = !latest.isEmpty && latest != installedVersion
    }

    private func localHarnessVersion(_ paths: Paths) -> String? {
        let package = paths.harness.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        guard let data = try? Data(contentsOf: package),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["version"] as? String
    }

    private func runtimeEnvironment(_ paths: Paths, extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(paths.runtime.appendingPathComponent("bin").path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        extra.forEach { environment[$0.key] = $0.value }
        return environment
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
        let pipe = Pipe()
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.environment = environment
        command.standardOutput = pipe
        command.standardError = pipe
        try command.run()
        return await withCheckedContinuation { continuation in
            command.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: output))
            }
        }
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

private struct ProcessResult {
    let status: Int32
    let output: String
}

private enum LauncherError: LocalizedError {
    case runtimeDownloadFailed
    case runtimeIntegrityFailed
    case harnessInstallFailed(String)
    case harnessMissing
    case harnessExited(Int32)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .runtimeDownloadFailed:
            return "The bundled Node.js runtime could not be downloaded. Check your internet connection and try again."
        case .runtimeIntegrityFailed:
            return "The downloaded Node.js runtime failed its integrity check."
        case let .harnessInstallFailed(output):
            return output.isEmpty ? "DeepSeek Harness could not be installed." : output
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
    @ObservedObject var harness: HarnessService

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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { harness.restart() }) {
                        Label("Restart Harness", systemImage: "arrow.clockwise")
                    }
                    Button(action: { harness.updateHarness() }) {
                        Label(harness.updateAvailable ? "Update Available" : "Update Harness", systemImage: "arrow.down.circle")
                    }
                    .help(updateHelp)
                    Button(action: openInBrowser) {
                        Label("Open in Browser", systemImage: "safari")
                    }
                }
            }
        }
        .task { harness.start() }
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
            if isWorking { ProgressView().controlSize(.small) }
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

    private var updateHelp: String {
        harness.updateAvailable ? "A newer DeepSeek Harness version is available." : "Check for and install the newest DeepSeek Harness version."
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

#Preview {
    ContentView(harness: .shared)
}

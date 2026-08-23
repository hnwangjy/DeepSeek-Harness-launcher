//
//  UpdateSupport.swift
//  deepseek launcher
//

import CryptoKit
import Foundation

nonisolated struct UpdatePackage: Equatable, Sendable {
    let version: String
    let tarballURL: URL
    let integrity: String?
    let shasum: String?
    let unpackedSize: Int64?
}

nonisolated struct UpdateDownloadState: Equatable, Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Double?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

nonisolated enum HarnessUpdateFlow: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdatePackage)
    case downloading(UpdateDownloadState)
    case verifying(UpdatePackage)
    case installing(UpdatePackage)
    case restarting(UpdatePackage)
    case ready(String)
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing, .restarting:
            return true
        default:
            return false
        }
    }
}

nonisolated protocol PackageMetadataFetching: Sendable {
    func fetchLatestPackage() async throws -> UpdatePackage
}

nonisolated struct NPMRegistryClient: PackageMetadataFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestPackage() async throws -> UpdatePackage {
        guard let url = URL(string: "https://registry.npmjs.org/%40deepseek-ai%2Fdsh/latest") else {
            throw UpdateSupportError.invalidMetadata
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateSupportError.registryUnavailable
        }
        return try UpdatePackageMetadataParser.parse(data)
    }
}

nonisolated enum UpdatePackageMetadataParser {
    static func parse(_ data: Data) throws -> UpdatePackage {
        do {
            let payload = try JSONDecoder().decode(RegistryPackagePayload.self, from: data)
            guard !payload.version.isEmpty else { throw UpdateSupportError.invalidMetadata }
            return UpdatePackage(
                version: payload.version,
                tarballURL: payload.dist.tarball,
                integrity: payload.dist.integrity,
                shasum: payload.dist.shasum,
                unpackedSize: payload.dist.unpackedSize
            )
        } catch {
            throw UpdateSupportError.invalidMetadata
        }
    }
}

private nonisolated struct RegistryPackagePayload: Decodable, Sendable {
    let version: String
    let dist: Distribution

    nonisolated struct Distribution: Decodable, Sendable {
        let tarball: URL
        let integrity: String?
        let shasum: String?
        let unpackedSize: Int64?
    }
}

nonisolated struct DownloadProgressSample: Equatable, Sendable {
    let downloadedBytes: Int64
    let expectedBytes: Int64?
}

nonisolated protocol PackageDownloading: Sendable {
    func download(
        _ package: UpdatePackage,
        to directory: URL,
        progress: @escaping (DownloadProgressSample) -> Void
    ) async throws -> URL
}

/// Downloads only the public npm tarball. It intentionally does not report npm
/// dependency resolution as a byte transfer because npm cannot provide that data.
nonisolated struct URLSessionPackageDownloader: PackageDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        _ package: UpdatePackage,
        to directory: URL,
        progress: @escaping (DownloadProgressSample) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: package.tarballURL)
        request.timeoutInterval = 60
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateSupportError.downloadFailed
        }

        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("dsh-update-\(UUID().uuidString).tgz")
        guard fileManager.createFile(atPath: archive.path, contents: nil) else {
            throw UpdateSupportError.downloadFailed
        }

        var downloaded: Int64 = 0
        var lastReported: Int64 = 0
        var buffer = Data()
        progress(DownloadProgressSample(downloadedBytes: 0, expectedBytes: expected))

        do {
            let handle = try FileHandle(forWritingTo: archive)
            defer { try? handle.close() }
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                downloaded += 1
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if downloaded - lastReported >= 64 * 1024 {
                    lastReported = downloaded
                    progress(DownloadProgressSample(downloadedBytes: downloaded, expectedBytes: expected))
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            progress(DownloadProgressSample(downloadedBytes: downloaded, expectedBytes: expected))
            return archive
        } catch {
            try? fileManager.removeItem(at: archive)
            throw error
        }
    }
}

nonisolated struct DownloadSpeedEstimator: Sendable {
    private var samples: [(bytes: Int64, uptime: TimeInterval)] = []
    private let window: TimeInterval

    init(window: TimeInterval = 3) {
        self.window = window
    }

    mutating func record(downloadedBytes: Int64, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        samples.append((downloadedBytes, uptime))
        samples.removeAll { uptime - $0.uptime > window }
        guard let first = samples.first, uptime > first.uptime, downloadedBytes >= first.bytes else { return nil }
        let rate = Double(downloadedBytes - first.bytes) / (uptime - first.uptime)
        return rate > 0 ? rate : nil
    }
}

nonisolated enum PackageIntegrityValidator {
    static func verify(archive: URL, package: UpdatePackage) throws {
        let data = try Data(contentsOf: archive, options: [.mappedIfSafe])
        if let integrity = package.integrity, let verified = verifySRI(integrity, data: data) {
            guard verified else { throw UpdateSupportError.integrityFailed }
            return
        }
        if let shasum = package.shasum,
           Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined().caseInsensitiveCompare(shasum) == .orderedSame {
            return
        }
        throw UpdateSupportError.integrityFailed
    }

    /// Returns nil when the registry's SRI uses no supported digest algorithm.
    /// A recognized digest mismatch must not fall through to a weaker checksum.
    private static func verifySRI(_ integrity: String, data: Data) -> Bool? {
        var foundSupportedAlgorithm = false
        for token in integrity.split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let expected = Data(base64Encoded: String(parts[1])) else { continue }
            switch parts[0].lowercased() {
            case "sha512":
                foundSupportedAlgorithm = true
                if Data(SHA512.hash(data: data)) == expected { return true }
            case "sha384":
                foundSupportedAlgorithm = true
                if Data(SHA384.hash(data: data)) == expected { return true }
            case "sha256":
                foundSupportedAlgorithm = true
                if Data(SHA256.hash(data: data)) == expected { return true }
            case "sha1":
                foundSupportedAlgorithm = true
                if Data(Insecure.SHA1.hash(data: data)) == expected { return true }
            default:
                continue
            }
        }
        return foundSupportedAlgorithm ? false : nil
    }
}

nonisolated struct LocalHarnessInstallCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]

    static func make(runtime: URL, prefix: URL, archive: URL, environment: [String: String]) -> LocalHarnessInstallCommand {
        LocalHarnessInstallCommand(
            executable: runtime.appendingPathComponent("bin/npm"),
            arguments: ["install", "--legacy-peer-deps", "--no-audit", "--no-fund", "--no-package-lock", "--prefix", prefix.path, archive.path],
            environment: environment
        )
    }

    static func addPeers(runtime: URL, prefix: URL, peers: [String], environment: [String: String]) -> LocalHarnessInstallCommand {
        LocalHarnessInstallCommand(
            executable: runtime.appendingPathComponent("bin/npm"),
            arguments: ["install", "--legacy-peer-deps", "--no-audit", "--no-fund", "--no-package-lock", "--prefix", prefix.path] + peers,
            environment: environment
        )
    }
}

nonisolated enum MissingPeerDependencyScanner {
    static func requiredPeers(in prefix: URL, fileManager: FileManager = .default) -> [String] {
        let modules = prefix.appendingPathComponent("node_modules", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: modules,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var missing: [String: String] = [:]
        for case let packageJSON as URL in enumerator where packageJSON.lastPathComponent == "package.json" {
            guard
                let data = try? Data(contentsOf: packageJSON),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let peers = object["peerDependencies"] as? [String: String]
            else { continue }
            let metadata = object["peerDependenciesMeta"] as? [String: [String: Any]] ?? [:]
            for (name, requirement) in peers where metadata[name]?["optional"] as? Bool != true {
                let installedManifest = modules
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("package.json")
                if !fileManager.fileExists(atPath: installedManifest.path) {
                    missing[name] = requirement
                }
            }
        }
        return missing.map { "\($0.key)@\($0.value)" }.sorted()
    }
}

nonisolated final class UpdateOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false

    nonisolated func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    nonisolated func release() {
        lock.lock()
        isHeld = false
        lock.unlock()
    }
}

nonisolated enum UpdateTemporaryFiles {
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

nonisolated enum UpdateDisplayFormatter {
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "正在连接…" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }
}

nonisolated struct UpdateToolbarPresentation: Equatable, Sendable {
    let title: String
    let symbol: String
    let showsProgress: Bool
    let isDisabled: Bool
    let visualSlotPoints: Int
    let accessibilityLabel: String
    let accessibilityValue: String
    let help: String

    static func make(isChecking: Bool, isAvailable: Bool, isUpdating: Bool) -> UpdateToolbarPresentation {
        if isUpdating {
            return UpdateToolbarPresentation(
                title: "正在更新",
                symbol: "arrow.triangle.2.circlepath",
                showsProgress: true,
                isDisabled: true,
                visualSlotPoints: 16,
                accessibilityLabel: "DeepSeek Harness 更新",
                accessibilityValue: "正在更新",
                help: "DeepSeek Harness 正在更新。"
            )
        }
        if isChecking {
            return UpdateToolbarPresentation(
                title: "正在检查",
                symbol: "arrow.triangle.2.circlepath",
                showsProgress: true,
                isDisabled: true,
                visualSlotPoints: 16,
                accessibilityLabel: "检查 DeepSeek Harness 更新",
                accessibilityValue: "正在检查",
                help: "正在检查 DeepSeek Harness 的最新版本。"
            )
        }
        if isAvailable {
            return UpdateToolbarPresentation(
                title: "发现更新",
                symbol: "arrow.triangle.2.circlepath",
                showsProgress: false,
                isDisabled: false,
                visualSlotPoints: 16,
                accessibilityLabel: "发现 DeepSeek Harness 更新",
                accessibilityValue: "有可用更新",
                help: "发现 DeepSeek Harness 新版本，点击检查详情。"
            )
        }
        return UpdateToolbarPresentation(
            title: "检查更新",
            symbol: "arrow.triangle.2.circlepath",
            showsProgress: false,
            isDisabled: false,
            visualSlotPoints: 16,
            accessibilityLabel: "检查 DeepSeek Harness 更新",
            accessibilityValue: "未在检查",
            help: "检查 DeepSeek Harness 的最新版本。"
        )
    }
}

nonisolated final class DownloadStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var estimator = DownloadSpeedEstimator()

    nonisolated func record(_ sample: DownloadProgressSample) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return estimator.record(downloadedBytes: sample.downloadedBytes)
    }
}

nonisolated enum UpdateSupportError: LocalizedError {
    case registryUnavailable
    case invalidMetadata
    case downloadFailed
    case integrityFailed
    case installFailed

    var errorDescription: String? {
        switch self {
        case .registryUnavailable: return "暂时无法检查更新，请稍后重试。"
        case .invalidMetadata: return "更新信息无效，请稍后重试。"
        case .downloadFailed: return "下载更新包失败，请检查网络后重试。"
        case .integrityFailed: return "更新包校验失败，未进行安装。"
        case .installFailed: return "更新安装失败，原始输出已隐藏以保护隐私。"
        }
    }
}

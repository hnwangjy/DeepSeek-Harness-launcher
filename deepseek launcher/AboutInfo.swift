//
//  AboutInfo.swift
//  deepseek launcher
//

import Foundation

nonisolated struct AppVersionInfo: Equatable, Sendable {
    static let productName = "DeepSeek Harness Launcher"

    let shortVersion: String
    let buildNumber: String

    init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    init(infoDictionary: [String: Any]?) {
        let shortVersion = infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = infoDictionary?["CFBundleVersion"] as? String
        self.shortVersion = Self.nonEmpty(shortVersion) ?? "未知版本"
        self.buildNumber = Self.nonEmpty(buildNumber) ?? "未知构建"
    }

    var buildDisplay: String { "Build \(buildNumber)" }

    func copyText(harness: HarnessVersionDisplay) -> String {
        "\(Self.productName) \(shortVersion) (\(buildNumber))\nDeepSeek Harness \(harness.copyValue)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

nonisolated enum HarnessVersionDisplay: Equatable, Sendable {
    case installed(String)
    case notInstalled
    case detecting
    case unavailable

    static func resolve(installedVersion: String?, status: HarnessService.Status) -> HarnessVersionDisplay {
        if let installedVersion = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !installedVersion.isEmpty {
            return .installed(installedVersion)
        }
        switch status {
        case .installingRuntime, .installingHarness, .starting, .updating:
            return .detecting
        case .failed:
            return .unavailable
        case .stopped, .ready:
            return .notInstalled
        }
    }

    var text: String {
        switch self {
        case let .installed(version): return version
        case .notInstalled: return "尚未安装"
        case .detecting: return "正在检测…"
        case .unavailable: return "无法读取"
        }
    }

    var copyValue: String { text }
}

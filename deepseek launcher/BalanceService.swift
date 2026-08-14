//
//  BalanceService.swift
//  deepseek launcher
//

import Combine
import Foundation

nonisolated struct AccountBalance: Identifiable, Equatable, Sendable {
    let currency: String
    let total: Decimal
    let granted: Decimal
    let toppedUp: Decimal

    var id: String { currency }
}

nonisolated struct BalanceSnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let balances: [AccountBalance]
}

nonisolated enum BalanceState: Equatable, Sendable {
    case idle
    case loading
    case available
    case unavailable
    case failed(stale: Bool)
}

nonisolated struct BalanceCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]

    static func managed(dshHome: URL) -> BalanceCommand {
        BalanceCommand(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [dshHome.appendingPathComponent("skills/dsk-account-balance/scripts/check_balance.sh").path],
            environment: [
                "DSH_HOME": dshHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        )
    }
}

nonisolated struct BalanceProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

protocol BalanceRunning: Sendable {
    nonisolated func run(_ command: BalanceCommand) throws -> BalanceProcessResult
}

nonisolated struct FoundationBalanceRunner: BalanceRunning {
    nonisolated func run(_ command: BalanceCommand) throws -> BalanceProcessResult {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = BalanceOutputCollector()
        let errorCollector = BalanceOutputCollector()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(standardError.fileHandleForReading.readDataToEndOfFile())

        return BalanceProcessResult(
            status: process.terminationStatus,
            standardOutput: String(data: outputCollector.data, encoding: .utf8) ?? "",
            standardError: String(data: errorCollector.data, encoding: .utf8) ?? ""
        )
    }
}

@MainActor
final class BalanceService: ObservableObject {
    @Published private(set) var state: BalanceState = .idle
    @Published private(set) var balances: [AccountBalance] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private let runner: any BalanceRunning
    private let dshHome: URL
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    var isRefreshing: Bool { refreshTask != nil }
    var hasHistoricalBalance: Bool { !balances.isEmpty }
    var primaryBalance: AccountBalance? { balances.first }
    var isStale: Bool {
        if case .failed(stale: true) = state { return true }
        return false
    }

    init(runner: any BalanceRunning = FoundationBalanceRunner(), dshHome: URL = ManagedDSHPaths.current().dshHome) {
        self.runner = runner
        self.dshHome = dshHome
    }

    deinit {
        refreshTask?.cancel()
        pollingTask?.cancel()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        state = .loading
        errorMessage = nil
        let runner = runner
        let command = BalanceCommand.managed(dshHome: dshHome)

        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try runner.run(command) }.value
                guard result.status == 0 else { throw BalanceServiceError.requestFailed }
                let snapshot = try BalancePayloadParser.parse(result.standardOutput)
                guard !Task.isCancelled else { return }
                self?.apply(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(error)
            }
        }
    }

    func setPolling(isActive: Bool) {
        guard isActive else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }
        refresh()
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func apply(_ snapshot: BalanceSnapshot) {
        if snapshot.isAvailable {
            balances = snapshot.balances
            state = .available
        } else {
            balances = snapshot.balances
            state = .unavailable
        }
        lastUpdated = Date()
        errorMessage = nil
    }

    private func applyFailure(_ error: Error) {
        state = .failed(stale: !balances.isEmpty)
        errorMessage = BalanceErrorSanitizer.message(for: error)
    }
}

nonisolated enum BalancePayloadParser {
    static func parse(_ output: String) throws -> BalanceSnapshot {
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isAvailable = root["is_available"] as? Bool else {
            throw BalanceServiceError.invalidResponse
        }

        let rawBalances = root["balance_infos"] as? [[String: Any]] ?? []
        if isAvailable && rawBalances.isEmpty { throw BalanceServiceError.invalidResponse }

        let balances = try rawBalances.map { raw -> AccountBalance in
            guard let currency = raw["currency"] as? String,
                  !currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let total = decimal(raw["total_balance"]),
                  let granted = decimal(raw["granted_balance"]),
                  let toppedUp = decimal(raw["topped_up_balance"]),
                  total >= 0, granted >= 0, toppedUp >= 0 else {
                throw BalanceServiceError.invalidResponse
            }
            return AccountBalance(currency: currency, total: total, granted: granted, toppedUp: toppedUp)
        }
        return BalanceSnapshot(isAvailable: isAvailable, balances: balances)
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        guard let text = value as? String else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

nonisolated enum BalanceFormatter {
    static func amount(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        if currency == "CNY" { formatter.currencySymbol = "¥" }
        return formatter.string(from: value as NSDecimalNumber) ?? "\(currency) \(value)"
    }
}

nonisolated enum BalanceErrorSanitizer {
    static func message(for error: Error) -> String {
        // Do not surface process output. It can contain server details or a
        // credential path, so every runner/parsing failure is mapped locally.
        switch error {
        case BalanceServiceError.invalidResponse:
            return "The balance response was invalid."
        case BalanceServiceError.requestFailed:
            return "Balance unavailable. Check the managed account configuration and try again."
        default:
            return "Balance unavailable. Please try again."
        }
    }
}

nonisolated enum BalanceServiceError: Error {
    case invalidResponse
    case requestFailed
}

private nonisolated final class BalanceOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    nonisolated func append(_ data: Data) {
        guard !data.isEmpty else { return }
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

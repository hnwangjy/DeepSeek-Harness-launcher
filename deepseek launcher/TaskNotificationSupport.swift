//
//  TaskNotificationSupport.swift
//  deepseek launcher
//

import Foundation

nonisolated enum TaskNotificationKind: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case stuck

    var title: String {
        switch self {
        case .completed: return "任务已完成"
        case .failed: return "任务运行出错"
        case .stuck: return "任务可能卡住"
        }
    }
}

nonisolated struct TaskNotificationPreferences: Codable, Equatable, Sendable {
    var isEnabled: Bool = false
    var notifyCompletion: Bool = true
    var notifyError: Bool = true
    var notifyStuck: Bool = true
    var stuckThresholdMinutes: Int = 10

    static let allowedThresholds = [5, 10, 20, 30]

    mutating func normalize() {
        if !Self.allowedThresholds.contains(stuckThresholdMinutes) {
            stuckThresholdMinutes = 10
        }
    }
}

nonisolated enum TaskNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case unavailable

    var description: String {
        switch self {
        case .notDetermined: return "尚未授权"
        case .authorized: return "已允许通知"
        case .denied: return "通知权限已拒绝"
        case .unavailable: return "通知不可用"
        }
    }
}

nonisolated enum HarnessEventConnectionState: Equatable, Sendable {
    case disabled
    case connecting
    case connected
    case reconnecting
    case unavailable

    var title: String {
        switch self {
        case .disabled: return "通知未启用"
        case .connecting: return "正在连接 Harness…"
        case .connected: return "已连接到 Harness"
        case .reconnecting: return "正在重新连接…"
        case .unavailable: return "等待 Harness 服务"
        }
    }

    var symbol: String {
        switch self {
        case .disabled: return "bell.slash"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.circle"
        }
    }
}

nonisolated enum HarnessEventURLBuilder {
    static func make(serverURL: URL) -> URL? {
        let endpoint = serverURL.appendingPathComponent("api/events.mux")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        return components.url
    }
}

nonisolated enum TaskNotificationConnectionPolicy {
    static func shouldConnect(
        isEnabled: Bool,
        authorization: TaskNotificationAuthorization,
        harnessIsReady: Bool
    ) -> Bool {
        isEnabled && authorization == .authorized && harnessIsReady
    }
}

nonisolated struct TaskNotificationEvent: Equatable, Sendable {
    let sessionID: String
    let turn: Int
    let kind: TaskNotificationKind
    let body: String
}

/// Parses only the `server-request` envelope used by the browser WebSocket.
/// The shape is verified against dsh-client-connection's `readWebSocket`:
/// `serverRequestSchema.parse(JSON.parse(event.data))`, then `full.payload`.
nonisolated enum HarnessMuxFrameParser {
    enum Frame {
        case subscribed(sessionID: String, lastSequence: Int)
        case event(sessionID: String, sequence: Int, type: String, data: [String: Any])
        case ignored
    }

    static func parse(_ text: String) throws -> Frame {
        guard let jsonData = text.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              envelope["type"] as? String == "server-request",
              envelope["rpcId"] as? String != nil,
              envelope["method"] as? String != nil,
              let payload = envelope["payload"] as? [String: Any],
              let frameType = payload["type"] as? String else {
            throw TaskNotificationProtocolError.invalidFrame
        }

        switch frameType {
        case "session/subscribed":
            guard let sessionID = payload["sessionId"] as? String,
                  let lastSequence = payload["lastSeq"] as? Int else {
                throw TaskNotificationProtocolError.invalidFrame
            }
            return .subscribed(sessionID: sessionID, lastSequence: lastSequence)
        case "session/event":
            guard let sessionID = payload["sessionId"] as? String,
                  let event = payload["event"] as? [String: Any],
                  let sequence = event["seq"] as? Int,
                  let type = event["type"] as? String else {
                throw TaskNotificationProtocolError.invalidFrame
            }
            return .event(sessionID: sessionID, sequence: sequence, type: type, data: event["data"] as? [String: Any] ?? [:])
        default:
            return .ignored
        }
    }
}

nonisolated enum TaskNotificationProtocolError: Error {
    case invalidFrame
}

/// Pure event state machine. It retains per-session sequence watermarks across
/// reconnects, so session/subscribed makes replayed events inert instead of
/// sending completion notifications for earlier turns.
nonisolated struct TaskNotificationEngine {
    private struct TurnState {
        var lastActivity: Date
        var hasEnded = false
        var completedNotified = false
        var errorNotified = false
        var stuckNotified = false
    }

    private struct SessionState {
        var lastSequence: Int
        var turns: [Int: TurnState] = [:]
    }

    private var sessions: [String: SessionState] = [:]

    mutating func consume(_ frame: HarnessMuxFrameParser.Frame, now: Date) -> [TaskNotificationEvent] {
        switch frame {
        case let .subscribed(sessionID, lastSequence):
            if var session = sessions[sessionID] {
                session.lastSequence = max(session.lastSequence, lastSequence)
                sessions[sessionID] = session
            } else {
                // `lastSeq` is the server's historical watermark at subscription.
                sessions[sessionID] = SessionState(lastSequence: lastSequence)
            }
            return []

        case let .event(sessionID, sequence, type, data):
            var session = sessions[sessionID] ?? SessionState(lastSequence: sequence - 1)
            guard sequence > session.lastSequence else { return [] }
            session.lastSequence = sequence

            // Activity in a session means an active turn is still making progress.
            for turn in session.turns.keys {
                guard var state = session.turns[turn], !state.hasEnded else { continue }
                state.lastActivity = now
                state.stuckNotified = false
                session.turns[turn] = state
            }

            let turn = Self.turn(from: data)
            var notifications: [TaskNotificationEvent] = []
            switch type {
            case "turn/start":
                if let turn {
                    session.turns[turn] = TurnState(lastActivity: now)
                }
            case "turn/end":
                if let turn {
                    var state = session.turns[turn] ?? TurnState(lastActivity: now)
                    state.lastActivity = now
                    state.hasEnded = true
                    let isError = Self.errorKind(from: data) == "error"
                    if isError, !state.errorNotified {
                        state.errorNotified = true
                        notifications.append(TaskNotificationEvent(
                            sessionID: sessionID,
                            turn: turn,
                            kind: .failed,
                            body: TaskNotificationErrorSanitizer.summary(from: data)
                        ))
                    } else if !isError, !state.completedNotified {
                        state.completedNotified = true
                        notifications.append(TaskNotificationEvent(
                            sessionID: sessionID,
                            turn: turn,
                            kind: .completed,
                            body: "本轮任务已完成。"
                        ))
                    }
                    session.turns[turn] = state
                }
            default:
                break
            }
            sessions[sessionID] = session
            return notifications

        case .ignored:
            return []
        }
    }

    mutating func stalledEvents(threshold: TimeInterval, now: Date) -> [TaskNotificationEvent] {
        guard threshold > 0 else { return [] }
        var events: [TaskNotificationEvent] = []
        for sessionID in sessions.keys {
            guard var session = sessions[sessionID] else { continue }
            for turn in session.turns.keys {
                guard var state = session.turns[turn],
                      !state.hasEnded,
                      !state.stuckNotified,
                      now.timeIntervalSince(state.lastActivity) >= threshold else { continue }
                state.stuckNotified = true
                session.turns[turn] = state
                events.append(TaskNotificationEvent(
                    sessionID: sessionID,
                    turn: turn,
                    kind: .stuck,
                    body: "超过 \(Int(threshold / 60)) 分钟没有新的任务活动。"
                ))
            }
            sessions[sessionID] = session
        }
        return events
    }

    private static func turn(from data: [String: Any]) -> Int? {
        if let turn = data["turn"] as? Int { return turn }
        if let turn = data["turn"] as? NSNumber { return turn.intValue }
        return nil
    }

    private static func errorKind(from data: [String: Any]) -> String? {
        (data["reason"] as? [String: Any])?["kind"] as? String
    }
}

nonisolated enum TaskNotificationErrorSanitizer {
    static func summary(from data: [String: Any]) -> String {
        let reason = data["reason"] as? [String: Any]
        let candidates = [
            reason?["message"] as? String,
            (reason?["error"] as? [String: Any])?["message"] as? String,
            (data["error"] as? [String: Any])?["message"] as? String,
            data["message"] as? String
        ]
        guard let candidate = candidates.compactMap({ $0 }).first else {
            return "任务执行时发生错误。"
        }
        let collapsed = candidate
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "任务执行时发生错误。" }
        let sensitive = "(?i)(authorization\\s*[:=]\\s*(?:bearer\\s+)?|bearer\\s+|api[ _-]?key\\s*[:=]\\s*|token\\s*[:=]\\s*|secret\\s*[:=]\\s*|password\\s*[:=]\\s*)[^\\s,;]+"
        let redacted = collapsed.replacingOccurrences(of: sensitive, with: "已隐藏", options: .regularExpression)
        return String(redacted.prefix(160))
    }
}

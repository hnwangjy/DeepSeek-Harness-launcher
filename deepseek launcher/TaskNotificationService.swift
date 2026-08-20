//
//  TaskNotificationService.swift
//  deepseek launcher
//

import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class TaskNotificationService: ObservableObject {
    static let shared = TaskNotificationService()

    @Published private(set) var preferences: TaskNotificationPreferences
    @Published private(set) var authorization: TaskNotificationAuthorization = .notDetermined
    @Published private(set) var connectionState: HarnessEventConnectionState = .disabled

    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var eventEngine = TaskNotificationEngine()
    private var harnessURL: URL?
    private var harnessIsReady = false
    private var appIsActive = true
    private var reconnectAttempt = 0

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        preferences = Self.loadPreferences(from: defaults)
        refreshAuthorization()
    }

    deinit {
        webSocket?.cancel(with: .goingAway, reason: nil)
        reconnectTask?.cancel()
        monitorTask?.cancel()
    }

    func harnessDidBecomeReady(serverURL: URL) {
        harnessURL = serverURL
        harnessIsReady = true
        connectIfNeeded()
    }

    func harnessDidBecomeUnavailable() {
        harnessIsReady = false
        reconnectTask?.cancel()
        reconnectTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if preferences.isEnabled { connectionState = .unavailable }
    }

    func setAppIsActive(_ active: Bool) {
        appIsActive = active
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            preferences.isEnabled = false
            persistPreferences()
            disconnectForDisabledState()
            return
        }

        switch authorization {
        case .authorized:
            preferences.isEnabled = true
            persistPreferences()
            connectIfNeeded()
        case .denied, .unavailable:
            preferences.isEnabled = false
            persistPreferences()
        case .notDetermined:
            requestAuthorizationForUserEnabledNotifications()
        }
    }

    func setNotifyCompletion(_ enabled: Bool) {
        preferences.notifyCompletion = enabled
        persistPreferences()
    }

    func setNotifyError(_ enabled: Bool) {
        preferences.notifyError = enabled
        persistPreferences()
    }

    func setNotifyStuck(_ enabled: Bool) {
        preferences.notifyStuck = enabled
        persistPreferences()
    }

    func setStuckThreshold(minutes: Int) {
        guard TaskNotificationPreferences.allowedThresholds.contains(minutes) else { return }
        preferences.stuckThresholdMinutes = minutes
        persistPreferences()
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestAuthorizationForUserEnabledNotifications() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAuthorization {
                    if granted, self.authorization == .authorized {
                        self.preferences.isEnabled = true
                        self.persistPreferences()
                        self.connectIfNeeded()
                    } else {
                        self.preferences.isEnabled = false
                        self.persistPreferences()
                    }
                }
            }
        }
    }

    private func refreshAuthorization(afterRefresh: (() -> Void)? = nil) {
        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorization = Self.mapAuthorization(settings.authorizationStatus)
                if let afterRefresh {
                    afterRefresh()
                } else {
                    // A persisted opt-in must resume after the asynchronous
                    // authorization lookup, without requesting permission.
                    self.connectIfNeeded()
                }
            }
        }
    }

    private func connectIfNeeded() {
        guard TaskNotificationConnectionPolicy.shouldConnect(
            isEnabled: preferences.isEnabled,
            authorization: authorization,
            harnessIsReady: harnessIsReady
        ) else {
            guard preferences.isEnabled, authorization == .authorized else {
                connectionState = .disabled
                return
            }
            connectionState = .unavailable
            return
        }
        guard let harnessURL,
              let endpoint = HarnessEventURLBuilder.make(serverURL: harnessURL) else {
            connectionState = .unavailable
            return
        }
        startStuckMonitorIfNeeded()
        guard webSocket == nil else { return }

        reconnectTask?.cancel()
        reconnectTask = nil
        connectionState = reconnectAttempt == 0 ? .connecting : .reconnecting
        if urlSession == nil { urlSession = URLSession(configuration: .default) }
        let socket = urlSession!.webSocketTask(with: endpoint)
        webSocket = socket
        socket.resume()
        receiveNext(on: socket)
    }

    private func receiveNext(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.webSocket === socket else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    self.receiveNext(on: socket)
                case .failure:
                    self.handleSocketClosed(socket)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case let .string(value):
            text = value
        case let .data(data):
            guard let value = String(data: data, encoding: .utf8) else { return }
            text = value
        @unknown default:
            return
        }

        guard let frame = try? HarnessMuxFrameParser.parse(text) else { return }
        connectionState = .connected
        reconnectAttempt = 0
        let events = eventEngine.consume(frame, now: Date())
        deliver(events)
    }

    private func handleSocketClosed(_ socket: URLSessionWebSocketTask) {
        guard webSocket === socket else { return }
        webSocket = nil
        guard preferences.isEnabled, authorization == .authorized, harnessIsReady else {
            connectionState = preferences.isEnabled ? .unavailable : .disabled
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectAttempt += 1
        connectionState = .reconnecting
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 4))))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connectIfNeeded()
        }
    }

    private func startStuckMonitorIfNeeded() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.checkForStalledTurns()
            }
        }
    }

    private func checkForStalledTurns() {
        guard harnessIsReady else { return }
        let threshold = TimeInterval(preferences.stuckThresholdMinutes * 60)
        deliver(eventEngine.stalledEvents(threshold: threshold, now: Date()))
    }

    private func deliver(_ events: [TaskNotificationEvent]) {
        guard preferences.isEnabled, authorization == .authorized, !appIsActive else { return }
        for event in events where isEnabled(event.kind) {
            let content = UNMutableNotificationContent()
            content.title = event.kind.title
            content.body = event.body
            content.sound = .default
            content.userInfo = ["sessionID": event.sessionID, "turn": event.turn]
            let identifier = "deepseek-harness.\(event.sessionID).\(event.turn).\(event.kind.rawValue).\(UUID().uuidString)"
            notificationCenter.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    private func isEnabled(_ kind: TaskNotificationKind) -> Bool {
        switch kind {
        case .completed: return preferences.notifyCompletion
        case .failed: return preferences.notifyError
        case .stuck: return preferences.notifyStuck
        }
    }

    private func disconnectForDisabledState() {
        reconnectTask?.cancel()
        reconnectTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        connectionState = .disabled
    }

    private func persistPreferences() {
        preferences.normalize()
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }

    private static let preferencesKey = "TaskNotificationPreferences.v1"

    private static func loadPreferences(from defaults: UserDefaults) -> TaskNotificationPreferences {
        guard let data = defaults.data(forKey: preferencesKey),
              var preferences = try? JSONDecoder().decode(TaskNotificationPreferences.self, from: data) else {
            return TaskNotificationPreferences()
        }
        preferences.normalize()
        return preferences
    }

    private static func mapAuthorization(_ status: UNAuthorizationStatus) -> TaskNotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }
}

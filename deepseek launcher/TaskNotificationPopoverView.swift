//
//  TaskNotificationPopoverView.swift
//  deepseek launcher
//

import SwiftUI

struct TaskNotificationPopoverView: View {
    @ObservedObject var notifications: TaskNotificationService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("任务通知")
                    .font(.headline)
                Spacer()
                connectionLabel
            }

            Toggle("启用任务通知", isOn: enabledBinding)
                .accessibilityHint("开启时才会请求 macOS 通知权限")

            if notifications.authorization == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Label("通知权限已被系统拒绝", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("前往系统设置", action: notifications.openNotificationSettings)
                        .controlSize(.small)
                }
                .accessibilityElement(children: .combine)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("任务完成", isOn: completionBinding)
                Toggle("任务报错", isOn: errorBinding)
                Toggle("疑似卡住", isOn: stuckBinding)
                Picker("卡住阈值", selection: thresholdBinding) {
                    ForEach(TaskNotificationPreferences.allowedThresholds, id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!notifications.preferences.isEnabled || !notifications.preferences.notifyStuck)
            }
            .disabled(!notifications.preferences.isEnabled)

            Text("仅当应用不活跃或窗口不在前台时发送通知。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务通知设置")
    }

    private var connectionLabel: some View {
        HStack(spacing: 5) {
            if notifications.connectionState == .connecting || notifications.connectionState == .reconnecting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: notifications.connectionState.symbol)
            }
            Text(notifications.connectionState.title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(connectionColor)
        .accessibilityLabel("连接状态：\(notifications.connectionState.title)")
    }

    private var connectionColor: Color {
        switch notifications.connectionState {
        case .connected: return .green
        case .unavailable: return .orange
        case .disabled, .connecting, .reconnecting: return .secondary
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { notifications.preferences.isEnabled }, set: notifications.setEnabled)
    }

    private var completionBinding: Binding<Bool> {
        Binding(get: { notifications.preferences.notifyCompletion }, set: notifications.setNotifyCompletion)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { notifications.preferences.notifyError }, set: notifications.setNotifyError)
    }

    private var stuckBinding: Binding<Bool> {
        Binding(get: { notifications.preferences.notifyStuck }, set: notifications.setNotifyStuck)
    }

    private var thresholdBinding: Binding<Int> {
        Binding(get: { notifications.preferences.stuckThresholdMinutes }, set: notifications.setStuckThreshold)
    }
}

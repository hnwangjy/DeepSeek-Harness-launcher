//
//  AboutLauncherView.swift
//  deepseek launcher
//

import AppKit
import SwiftUI

struct AboutLauncherView: View {
    @ObservedObject var harness: HarnessService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var didCopy = false

    private let appVersion = AppVersionInfo()

    private var harnessVersion: HarnessVersionDisplay {
        HarnessVersionDisplay.resolve(installedVersion: harness.installedVersion, status: harness.status)
    }

    var body: some View {
        VStack(spacing: 15) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityLabel("DeepSeek Harness Launcher 图标")

            VStack(spacing: 4) {
                Text(AppVersionInfo.productName)
                    .font(.title3.weight(.semibold))
                Text("用于运行和管理本地 DeepSeek Harness 服务。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 0) {
                versionRow(label: "启动器版本", value: appVersion.shortVersion)
                Divider().padding(.leading, 122)
                versionRow(label: "构建版本", value: appVersion.buildDisplay)
                Divider().padding(.leading, 122)
                versionRow(label: "DeepSeek Harness", value: harnessVersion.text, showsActivity: harnessVersion == .detecting)
            }
            .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: copyVersionInfo) {
                Label(didCopy ? "已复制" : "复制版本信息", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(didCopy ? "版本信息已复制" : "复制版本信息")
            .accessibilityHint("将启动器和 DeepSeek Harness 版本复制到剪贴板")
        }
        .padding(24)
        .frame(width: 410, height: 305)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.22), value: didCopy)
    }

    private func versionRow(label: String, value: String, showsActivity: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 106, alignment: .leading)
            if showsActivity {
                ProgressView().controlSize(.small)
            }
            Text(value)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }

    private func copyVersionInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appVersion.copyText(harness: harnessVersion), forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            didCopy = false
        }
    }
}

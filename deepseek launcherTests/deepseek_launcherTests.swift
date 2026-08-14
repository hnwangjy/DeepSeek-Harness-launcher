//
//  deepseek_launcherTests.swift
//  deepseek launcherTests
//
//  Created by wjy on 2026/8/14.
//

import Testing
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

}

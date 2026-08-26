<p align="center">
  <img src="deepseek%20launcher/Assets.xcassets/AppIcon.appiconset/deepseek-launcher-icon-1024.png" width="128" alt="DeepSeek Harness Launcher 图标">
</p>

<h1 align="center">DeepSeek Harness Launcher</h1>

<p align="center">
  一个用于安装、运行和管理本地 DeepSeek Harness 的原生 macOS 启动器。
</p>

> [!NOTE]
> 这是社区项目，并非 DeepSeek 官方客户端。目前只支持 macOS；Windows 版本暂未继续开发。

## 它能做什么

- **开箱即用地启动 Harness**：首次运行时自动准备托管的 Node.js 运行时和最新 DeepSeek Harness。
- **内置工作区**：直接在原生窗口中使用 Harness，也可以一键在浏览器中打开。
- **安全更新**：检查并安装 Harness 更新，显示更新包大小、已下载大小和实时下载速度；新版本验证成功后才会替换旧版本。
- **插件管理**：查看本地 Web Profile 中的插件，并从经过固定版本审查的目录安装插件。
- **账户余额**：通过本地 `dsk-account-balance` skill 展示 DeepSeek 账户余额，并保留最后一次成功结果。
- **任务通知**：任务完成、发生错误或疑似卡住时发送 macOS 通知，支持自定义卡住阈值。
- **版本信息**：在“关于”窗口中查看并复制 Launcher 与 DeepSeek Harness 的版本。

## 当前内置插件目录

| 插件 | 用途 | 安装状态 |
| --- | --- | --- |
| [dsh-at-file](https://github.com/omdsh-dev/dsh-at-file) | 文件导航与 `@文件` 引用 | 可直接安装 |
| [dsh-genui](https://github.com/omdsh-dev/dsh-genui) | 生成式 UI 支持 | 可直接安装 |
| [DSH-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar) | 增强侧边栏、终端、Git 与文件访问 | 需要额外批准原生构建脚本 |
| [ModLens](https://github.com/liustack/modlens) | Harness 可视化工具 | 安装后需要配置 |

插件安装源和版本均固定在 [`PluginStore.swift`](deepseek%20launcher/PluginStore.swift) 中，不会静默安装 `latest`。

## 环境要求

- Apple Silicon Mac
- macOS 26.5 或更高版本（当前工程的 Deployment Target）
- 可构建该目标版本的 Xcode
- 首次运行及检查更新时需要联网

Launcher 会自行下载项目指定的 Node.js 运行时，无需预先安装 Node.js 或 npm。

## 从源码运行

1. 克隆仓库：

   ```bash
   git clone https://github.com/hnwangjy/DeepSeek-Harness-launcher.git
   cd DeepSeek-Harness-launcher
   ```

2. 用 Xcode 打开工程：

   ```bash
   open "deepseek launcher.xcodeproj"
   ```

3. 在 Xcode 中选择 `deepseek launcher` Scheme 和 `My Mac`，然后点击 Run。

首次启动会依次完成：

1. 创建应用数据目录；
2. 下载并校验托管的 Node.js 运行时；
3. 下载、校验和安装最新 DeepSeek Harness；
4. 在 `127.0.0.1:3080` 启动本地服务；
5. 在应用窗口中载入 Harness 工作区。

首次安装需要下载依赖，耗时取决于网络状况。

## 使用说明

Harness 启动完成后，窗口工具栏提供以下入口：

- **余额**：查看账户余额并手动刷新；若本地未安装 `dsk-account-balance`，会显示不可用。
- **通知**：选择是否通知任务完成、报错或长时间无进展。
- **Plugins**：同步已安装插件、查看状态并安装目录中的插件。
- **更新**：手动检查 Harness 更新；有新版本时会显示安装确认和更新进度。
- **浏览器**：使用系统默认浏览器打开本地 Harness。

应用菜单中的“关于 DeepSeek Harness Launcher”可以查看 Launcher、构建号和 Harness 版本。

## 本地数据

所有托管数据都保存在：

```text
~/Library/Application Support/DeepSeek Harness/
├── runtime/       # Launcher 管理的 Node.js 运行时
├── harness/       # 当前安装的 DeepSeek Harness
├── dsh-home/      # DSH 配置、Profile 与 Skills
├── workspace/     # 本地工作区
└── harness.log    # Harness 启动日志
```

更新采用临时目录安装和完整性校验。只有新版本准备完成后才会停止当前服务并替换安装目录；启动失败时会尝试恢复原版本。

## 隐私与安全

- Harness 仅监听 `127.0.0.1:3080`，不会直接暴露到局域网。
- Launcher 使用独立的 `DSH_HOME`，不会读取或修改其他工具的配置目录。
- 更新包会根据 npm Registry 提供的 integrity 或 SHA-1 信息进行校验。
- 插件目录使用固定版本或固定提交；需要原生构建脚本的插件不会自动获得批准。
- 安装失败信息会进行简化，避免在界面中泄露本地路径或敏感输出；完整诊断信息保留在本地日志中。

## 测试与构建

运行单元测试：

```bash
xcodebuild test \
  -project "deepseek launcher.xcodeproj" \
  -scheme "deepseek launcher" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:'deepseek launcherTests' \
  CODE_SIGNING_ALLOWED=NO
```

构建 Release：

```bash
xcodebuild build \
  -project "deepseek launcher.xcodeproj" \
  -scheme "deepseek launcher" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

未签名的构建只适合本机开发和测试。面向其他设备分发时仍需配置 Apple Developer 签名、公证和发布流程。

## 常见问题

### 一直停留在“正在安装依赖”

请先更新到仓库最新版本。Launcher 已针对 npm peer dependency 回溯和大量输出造成的阻塞进行处理。若仍失败，请查看 `harness.log` 和应用数据目录下的 npm 日志。

### 出现 `window.__ModuleLoader__ bootstrap facade is missing`

这通常说明旧 Harness 进程仍占用 3080 端口，但磁盘上的前端文件已经更新。最新版 Launcher 会记录并接管自己启动的 Harness 进程，更新前确认旧服务已经停止。

### 余额显示不可用

余额功能依赖：

```text
~/Library/Application Support/DeepSeek Harness/dsh-home/skills/dsk-account-balance/scripts/check_balance.sh
```

确认该 skill 已安装、脚本可执行，并且 DeepSeek 账户配置有效。

### 3080 端口被占用

退出所有旧版 Launcher 与手动启动的 Harness 后重新打开应用。不要同时运行多个 Launcher 实例。

## 项目结构

```text
deepseek launcher/
├── ContentView.swift                  # 主窗口、服务生命周期与更新流程
├── PluginStore.swift                  # 插件目录、发现和安装
├── BalanceService.swift               # 余额读取与轮询
├── TaskNotificationService.swift      # Harness 信息流与系统通知
├── UpdateSupport.swift                # 下载、校验和更新支持
└── Assets.xcassets/                   # 应用图标与资源
```

欢迎通过 GitHub Issues 提交可复现的问题和功能建议。报告问题时请附上 Launcher 版本、Harness 版本和经过脱敏的错误信息。

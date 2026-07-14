import SwiftUI

struct ProcessRouteApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("路由切换器") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("路由") {
                Button("选中 → 走 VPN") { model.applyModeToSelection(.vpn) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("选中 → 走本地") { model.applyModeToSelection(.local) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("选中 → 系统默认") { model.applyModeToSelection(.system) }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Form {
            Section("全局默认") {
                Picker("未单独设置的进程", selection: Binding(
                    get: { model.defaultMode },
                    set: { model.setDefaultMode($0) }
                )) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.defaultPolicyTitle).tag(mode)
                    }
                }
                Text("进程级规则优先。全局默认改变后会立即重新应用路由。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("显示") {
                Toggle("默认仅显示有网络连接的进程", isOn: $model.showOnlyWithConnections)
            }
            Section("说明") {
                Text("首次需要改路由时输入一次管理员密码；本会话内改规则不必再输入。退出应用后需重新授权。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("限制：同一目标 IP 被多个进程共用时只能有一种策略；新连接的首包可能短暂走默认路由，随后会纠正。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("名称", value: "路由切换器")
                LabeledContent("版本", value: AppVersion.current)
                LabeledContent("最低系统", value: "macOS 14+")
                Button("检查更新…") {
                    Task { await model.checkForUpdates(silent: false) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 360)
        .padding()
    }
}

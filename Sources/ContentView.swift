import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { model.start() }
        .alert("错误", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("好", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("网络状态") {
                networkRow(
                    title: "VPN",
                    ok: model.network.vpnAvailable,
                    detail: model.network.vpnSummary
                )
                networkRow(
                    title: "本地网关",
                    ok: model.network.localAvailable,
                    detail: model.network.localSummary
                )
                networkRow(
                    title: "系统默认出口",
                    ok: true,
                    detail: {
                        let iface = model.network.defaultInterface ?? "?"
                        return model.network.isVPNDefault ? "\(iface) (VPN)" : "\(iface) (本地)"
                    }()
                )
                networkRow(
                    title: "管理员权限",
                    ok: model.privilegeReady,
                    detail: model.privilegeReady ? "已授权（本会话无需再输入）" : "尚未授权"
                )
            }

            Section("全局默认") {
                Picker("未单独设置的进程", selection: Binding(
                    get: { model.defaultMode },
                    set: { model.setDefaultMode($0) }
                )) {
                    ForEach(RouteMode.allCases) { mode in
                        Label(mode.defaultPolicyTitle, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text("进程单独规则优先于全局默认。清除某进程规则后，会重新跟随此处设置。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("进程规则 (\(model.rules.count))") {
                if model.rules.isEmpty {
                    Text("可在右侧为个别进程覆盖全局默认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.rules) { rule in
                        ruleRow(rule)
                    }
                }
            }

            Section("已应用主机路由 (\(model.appliedRoutes.count))") {
                if !model.lastMatchSummary.isEmpty {
                    Text(model.lastMatchSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if model.appliedRoutes.isEmpty {
                    Text(model.defaultMode == .system && model.rules.isEmpty
                         ? "先设「全局默认」，或为进程单独指定 VPN/本地"
                         : "尚无主机路由。点刷新重试；确认目标进程有外连")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.appliedRoutes) { route in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: route.mode.systemImage)
                                    .foregroundStyle(route.mode == .vpn ? Color.blue : Color.green)
                                Text(route.destination)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            Text("\(route.processName) · \(route.via)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func networkRow(title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func ruleRow(_ rule: RouteRule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: rule.mode.systemImage)
                .foregroundStyle(rule.mode == .vpn ? Color.blue : Color.green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.processName)
                    .lineLimit(1)
                Text(rule.mode.title + (rule.enabled ? "" : " · 已禁用"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in model.toggleRule(rule) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .contextMenu {
            Button("删除规则", role: .destructive) {
                model.removeRule(rule)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            processList
            Divider()
            bottomBar
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索进程名 / Bundle ID / PID", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
            Toggle("仅有连接", isOn: $model.showOnlyWithConnections)
                .toggleStyle(.checkbox)
                .help("只显示当前有外网连接的进程")
            Toggle("含系统", isOn: $model.includeSystem)
                .toggleStyle(.checkbox)
                .onChange(of: model.includeSystem) { _, _ in model.refreshAll() }
            Spacer()
            Text("显示 \(model.filteredProcesses.count) / 共 \(model.processes.count)")
                .foregroundStyle(.secondary)
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var processList: some View {
        Group {
            if model.filteredProcesses.isEmpty {
                emptyState
            } else {
                List(selection: $model.selectedIDs) {
                    ForEach(model.filteredProcesses) { item in
                        processRow(item)
                            .tag(item.id)
                            .contextMenu {
                                Button("走 VPN") { model.applyMode(.vpn, to: [item]) }
                                Button("走本地") { model.applyMode(.local, to: [item]) }
                                Divider()
                                Button("恢复系统默认") { model.applyMode(.system, to: [item]) }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if model.isRefreshing || model.processes.isEmpty {
                ProgressView("正在扫描进程…")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("没有匹配的进程")
                    .font(.headline)
                Text("试试取消「仅有连接」，或清空搜索框；也可点工具栏刷新")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func processRow(_ item: ProcessItem) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: model.appIcon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if item.connectionCount > 0 {
                        Text("\(item.connectionCount) 连接")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(item.matchKey)  ·  PID \(item.pid)（含多窗口/Helper）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.remoteIPs.isEmpty {
                    Text(item.remoteIPs.prefix(4).joined(separator: ", ")
                         + (item.remoteIPs.count > 4 ? " …" : ""))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            modeBadge(for: item)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func modeBadge(for item: ProcessItem) -> some View {
        let mode = model.mode(for: item)
        let explicit = model.hasExplicitRule(for: item)
        let label: String = {
            if explicit { return mode.shortTitle }
            if mode == .system { return "系统" }
            return "默·\(mode.shortTitle)"
        }()
        return HStack(spacing: 4) {
            Image(systemName: mode.systemImage)
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeColor(mode).opacity(explicit ? 0.18 : 0.10), in: Capsule())
        .foregroundStyle(badgeColor(mode))
        .help(explicit ? "进程单独规则：\(mode.title)" : "跟随全局默认：\(mode.defaultPolicyTitle)")
    }

    private func badgeColor(_ mode: RouteMode) -> Color {
        switch mode {
        case .system: return .secondary
        case .vpn: return .blue
        case .local: return .green
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Label(model.statusMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text("已选 \(model.selectedIDs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.applyModeToSelection(.vpn)
            } label: {
                Label("走 VPN", systemImage: "lock.shield.fill")
            }
            .disabled(model.selectedIDs.isEmpty)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help("将选中进程的目标地址路由到 VPN")

            Button {
                model.applyModeToSelection(.local)
            } label: {
                Label("走本地", systemImage: "house.fill")
            }
            .disabled(model.selectedIDs.isEmpty)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help("将选中进程的目标地址绕过 VPN 走本地网关")

            Button {
                model.applyModeToSelection(.system)
            } label: {
                Label("跟随默认", systemImage: "circle.dashed")
            }
            .disabled(model.selectedIDs.isEmpty)
            .help("清除该进程单独规则，改回跟随左侧「全局默认」")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.refreshAndApply()
            } label: {
                if model.isRefreshing || model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshing || model.isBusy)
            .help("刷新进程，并重新应用路由规则（可能需要管理员密码）")
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

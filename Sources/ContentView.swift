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
        .alert("发现新版本", isPresented: $model.showUpdateAlert) {
            Button("取消", role: .cancel) { model.dismissUpdateAlert() }
            Button("更新") { model.confirmUpdate() }
        } message: {
            Text(model.updateAlertMessage)
        }
        .overlay {
            if model.isUpdating {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(model.updateStatus.isEmpty ? "正在更新…" : model.updateStatus)
                            .font(.headline)
                        Text("下载完成后将自动替换并重启")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
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

            Section("全局默认（中间档）") {
                // 与行内一致：左 VPN · 中 默认 · 右 本地
                Picker("未单独设置的进程", selection: Binding(
                    get: { model.defaultMode },
                    set: { model.setDefaultMode($0) }
                )) {
                    ForEach(RouteMode.switchOrder) { mode in
                        Text(mode.switchLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // App 左下角版本号（年-月日）
            HStack(spacing: 6) {
                Text("version \(model.appVersion)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .help("当前版本（年-月日）。双击可手动检查 GitHub 更新。")
            .onTapGesture(count: 2) {
                Task { await model.checkForUpdates(silent: false) }
            }
        }
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
                // 按父进程/应用归类（ProcessMonitor 已合并 Helper）
                List(selection: $model.selectedIDs) {
                    Section {
                        HStack {
                            Text("应用（按父进程归类）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("VPN    默认    本地")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(model.filteredProcesses) { item in
                        processRow(item)
                            .tag(item.id)
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
                Text("\(item.matchKey)  ·  PID \(item.pid)（含 Helper/子进程）")
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

            Spacer(minLength: 8)

            // 左 VPN · 中 默认 · 右 本地
            modeSwitch(for: item)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// 三档切换：左 VPN / 中 默认 / 右 本地
    private func modeSwitch(for item: ProcessItem) -> some View {
        // 显示「生效策略」：有单独规则用规则，否则中间「默认」
        let selected: RouteMode = {
            if model.hasExplicitRule(for: item) {
                return model.mode(for: item)
            }
            return .system
        }()

        return HStack(spacing: 0) {
            ForEach(RouteMode.switchOrder) { mode in
                let on = selected == mode
                Button {
                    model.applyMode(mode, to: [item])
                } label: {
                    Text(mode.switchLabel)
                        .font(.caption.weight(on ? .semibold : .regular))
                        .frame(minWidth: 40)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            on
                                ? switchFill(mode)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(on ? switchFg(mode) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(switchHelp(mode, item: item))
            }
        }
        .padding(3)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func switchFill(_ mode: RouteMode) -> Color {
        switch mode {
        case .vpn: return Color.blue.opacity(0.9)
        case .system: return Color.primary.opacity(0.12)
        case .local: return Color.green.opacity(0.85)
        }
    }

    private func switchFg(_ mode: RouteMode) -> Color {
        switch mode {
        case .vpn, .local: return .white
        case .system: return .primary
        }
    }

    private func switchHelp(_ mode: RouteMode, item: ProcessItem) -> String {
        switch mode {
        case .vpn: return "\(item.name) → VPN"
        case .system: return "\(item.name) → 默认（全局：\(model.defaultMode.defaultPolicyTitle)）"
        case .local: return "\(item.name) → 本地"
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Label(model.statusMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // 批量：左 VPN · 中 默认 · 右 本地
            Text("已选 \(model.selectedIDs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Button("VPN") { model.applyModeToSelection(.vpn) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("选中 → VPN")
                Button("默认") { model.applyModeToSelection(.system) }
                    .help("选中 → 默认")
                Button("本地") { model.applyModeToSelection(.local) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help("选中 → 本地")
            }
            .disabled(model.selectedIDs.isEmpty)
            .controlSize(.small)
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

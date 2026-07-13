import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var processes: [ProcessItem] = []
    @Published var rules: [RouteRule] = []
    @Published var network: NetworkSnapshot = .empty
    @Published var appliedRoutes: [AppliedRoute] = []
    @Published var selectedIDs: Set<ProcessItem.ID> = []
    @Published var searchText: String = ""
    @Published var showOnlyWithConnections: Bool = false
    @Published var includeSystem: Bool = false
    @Published var isBusy: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var statusMessage: String = "就绪"
    @Published var lastError: String?
    @Published var lastMatchSummary: String = ""
    @Published var privilegeReady: Bool = false
    /// 未单独设规则的进程：跟随系统 / 默认 VPN / 默认本地
    @Published var defaultMode: RouteMode = .system

    private let engine = RouteEngine()
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var didStart = false
    private var didInitialRouteApply = false
    private var terminateObserver: NSObjectProtocol?

    /// 是否需要写主机路由（有进程规则或全局默认非 system）
    private var hasActiveRules: Bool {
        defaultMode == .vpn || defaultMode == .local
            || rules.contains { $0.enabled && $0.mode != .system }
    }

    var filteredProcesses: [ProcessItem] {
        processes.filter { item in
            if showOnlyWithConnections && item.connectionCount == 0 {
                if rule(for: item) == nil { return false }
            }
            if searchText.isEmpty { return true }
            let q = searchText
            return item.name.localizedCaseInsensitiveContains(q)
                || item.matchKey.localizedCaseInsensitiveContains(q)
                || "\(item.pid)".contains(q)
        }
    }

    var selectedProcesses: [ProcessItem] {
        processes.filter { selectedIDs.contains($0.id) }
    }

    func rule(for item: ProcessItem) -> RouteRule? {
        rules.first { ProcessMonitor.matches($0, process: item) && $0.enabled }
    }

    /// 生效策略：进程规则优先，否则全局默认
    func mode(for item: ProcessItem) -> RouteMode {
        if let r = rule(for: item), r.mode != .system {
            return r.mode
        }
        return defaultMode
    }

    /// 是否为进程单独指定的规则（非继承全局默认）
    func hasExplicitRule(for item: ProcessItem) -> Bool {
        rule(for: item) != nil
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else {
            refreshAll()
            return
        }
        didStart = true
        rules = RuleStore.shared.load()
        defaultMode = RuleStore.shared.loadDefaultMode()
        statusMessage = "正在加载进程…"
        refreshAll()

        // 启动时只提权一次；之后改规则 / 定时同步都不再弹密码
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await preparePrivilegeAndApplyIfNeeded()
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.refreshAll()
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.cleanupOnQuit()
            }
        }
    }

    /// 首次（或 helper 挂掉时）提权；有规则则顺带应用
    private func preparePrivilegeAndApplyIfNeeded() async {
        if await PrivilegeSession.shared.isReady() {
            privilegeReady = true
            statusMessage = "管理员权限已就绪（本次运行无需再输入密码）"
            if hasActiveRules {
                didInitialRouteApply = true
                await syncRoutes(silent: true, reason: "启动同步")
            }
            return
        }

        // 有规则，或用户稍后会设规则：主动提权一次
        statusMessage = "需要管理员权限以修改路由（仅此一次）…"
        do {
            try await PrivilegeSession.shared.ensurePrivileged()
            privilegeReady = true
            statusMessage = "管理员权限已就绪，之后无需再输入密码"
            if hasActiveRules {
                didInitialRouteApply = true
                await syncRoutes(silent: true, reason: "启动同步")
            }
        } catch {
            privilegeReady = false
            // 无规则时提权失败不硬弹；有规则时提示
            if hasActiveRules {
                lastError = error.localizedDescription
                statusMessage = "授权失败：\(error.localizedDescription)"
            } else {
                statusMessage = "稍后设置路由规则时将请求一次管理员密码"
            }
        }
    }

    private func cleanupOnQuit() async {
        refreshTask?.cancel()
        refreshTask = nil
        try? await engine.clearAll()
        await PrivilegeSession.shared.shutdownHelper()
    }

    func refreshAll() {
        refreshGeneration &+= 1
        let gen = refreshGeneration
        let includeSys = includeSystem
        let shouldSync = hasActiveRules && didInitialRouteApply
        isRefreshing = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let net = NetworkInterfaceManager.snapshot()
            let list = ProcessMonitor.listProcesses(includeSystem: includeSys)

            await MainActor.run {
                guard let self, self.refreshGeneration == gen else { return }
                self.network = net
                self.processes = list
                self.isRefreshing = false

                let withConn = list.filter { $0.connectionCount > 0 }.count
                if !self.isBusy {
                    self.statusMessage =
                        "进程 \(list.count) · 有连接 \(withConn) · VPN \(net.vpnAvailable ? "✓" : "✗") · 本地 \(net.localAvailable ? "✓" : "✗")"
                }
            }

            guard let self else { return }
            if shouldSync {
                // 后台静默同步：已授权时能更新；失败不弹窗刷屏
                await self.syncRoutes(silent: true, reason: "定时同步")
            }
        }
    }

    // MARK: - Rules

    func applyMode(_ mode: RouteMode, to items: [ProcessItem]) {
        guard !items.isEmpty else {
            statusMessage = "请先选择一个或多个进程"
            return
        }
        for item in items {
            RuleStore.shared.setMode(
                mode,
                matchKey: item.matchKey,
                processName: item.name,
                rules: &rules
            )
        }
        let names = items.map(\.name).joined(separator: "、")
        statusMessage = mode == .system
            ? "已清除 \(names) 的单独规则（将跟随全局默认：\(defaultMode.defaultPolicyTitle)）"
            : "已设置 \(names) → \(mode.title)，正在写入路由…"
        didInitialRouteApply = true
        Task { await ensurePrivilegeThenSync(reason: "手动设置规则") }
    }

    func applyModeToSelection(_ mode: RouteMode) {
        applyMode(mode, to: selectedProcesses)
    }

    /// 设置全局默认：未单独配置的进程走 VPN / 本地 / 跟随系统
    func setDefaultMode(_ mode: RouteMode) {
        guard defaultMode != mode else { return }
        defaultMode = mode
        RuleStore.shared.saveDefaultMode(mode)
        statusMessage = "全局默认已设为「\(mode.defaultPolicyTitle)」"
        didInitialRouteApply = true
        Task { await ensurePrivilegeThenSync(reason: "修改全局默认") }
    }

    private func ensurePrivilegeThenSync(reason: String) async {
        if hasActiveRules {
            if !(await PrivilegeSession.shared.isReady()) {
                statusMessage = "首次设置需管理员密码（仅一次）…"
                do {
                    try await PrivilegeSession.shared.ensurePrivileged()
                    privilegeReady = true
                } catch {
                    lastError = error.localizedDescription
                    statusMessage = "授权失败"
                    return
                }
            }
        }
        await syncRoutes(silent: false, reason: reason)
    }

    func removeRule(_ rule: RouteRule) {
        RuleStore.shared.remove(id: rule.id, from: &rules)
        statusMessage = "已删除规则：\(rule.processName)"
        Task { await syncRoutes(silent: false, reason: "删除规则") }
    }

    func toggleRule(_ rule: RouteRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx].enabled.toggle()
        RuleStore.shared.save(rules)
        Task { await syncRoutes(silent: false, reason: "切换规则") }
    }

    /// 用户点刷新时，若有规则也强制重新写路由（不重复要密码）
    func refreshAndApply() {
        Task {
            isRefreshing = true
            let includeSys = includeSystem
            let (net, list) = await Task.detached(priority: .userInitiated) {
                (NetworkInterfaceManager.snapshot(), ProcessMonitor.listProcesses(includeSystem: includeSys))
            }.value
            network = net
            processes = list
            isRefreshing = false
            if hasActiveRules {
                didInitialRouteApply = true
                if !(await PrivilegeSession.shared.isReady()) {
                    do {
                        try await PrivilegeSession.shared.ensurePrivileged()
                        privilegeReady = true
                    } catch {
                        lastError = error.localizedDescription
                        statusMessage = "授权失败，无法写入路由"
                        return
                    }
                }
                await syncRoutes(silent: false, reason: "手动刷新并应用")
            } else {
                statusMessage = "已刷新 · 进程 \(list.count) · 当前跟随系统（无强制路由）"
            }
        }
    }

    // MARK: - 路由同步

    private func syncRoutes(silent: Bool, reason: String) async {
        if !silent { isBusy = true }
        defer { if !silent { isBusy = false } }

        if !hasActiveRules {
            do {
                try await engine.clearAll()
                appliedRoutes = []
                lastMatchSummary = ""
                if !silent { statusMessage = "已清除全部自定义路由" }
            } catch {
                if !silent { lastError = error.localizedDescription }
            }
            return
        }

        do {
            let result = try await performSync()
            lastMatchSummary = result.summary
            if !silent {
                if result.ipCount == 0 {
                    statusMessage =
                        "规则 \(rules.filter(\.enabled).count) 条已生效条件不足：匹配到 0 个外连 IP。请确认目标 App 正在上网（\(reason)）"
                    lastError =
                        "未匹配到外连 IP。\nVPN: \(network.vpnSummary)\n本地: \(network.localSummary)\n\(result.summary)"
                } else {
                    statusMessage = "已写入 \(appliedRoutes.count) 条主机路由（\(reason)）"
                }
            }
        } catch {
            if !silent {
                lastError = error.localizedDescription
                statusMessage = "应用路由失败：\(error.localizedDescription)"
            }
        }
    }

    private struct SyncResult {
        let ipCount: Int
        let summary: String
    }

    private func performSync() async throws -> SyncResult {
        let includeSys = includeSystem
        let currentRules = rules
        let globalDefault = defaultMode

        let (net, list) = await Task.detached(priority: .userInitiated) {
            let net = NetworkInterfaceManager.snapshot()
            let list = ProcessMonitor.listProcesses(includeSystem: includeSys)
            return (net, list)
        }.value

        network = net
        processes = list

        let needsVPN = globalDefault == .vpn
            || currentRules.contains { $0.enabled && $0.mode == .vpn }
        let needsLocal = globalDefault == .local
            || currentRules.contains { $0.enabled && $0.mode == .local }

        if needsVPN && !net.vpnAvailable {
            throw AppError.noVPN
        }
        if needsLocal && !net.localAvailable {
            throw AppError.noLocalGateway
        }

        let targets = ProcessMonitor.remoteIPs(
            matching: currentRules,
            processes: list,
            defaultMode: globalDefault
        )
        let vpnN = targets[.vpn]?.count ?? 0
        let localN = targets[.local]?.count ?? 0
        let ipCount = vpnN + localN

        let matchedApps = currentRules.filter(\.enabled).compactMap { rule -> String? in
            let hit = list.first { ProcessMonitor.matches(rule, process: $0) }
            let n = hit?.remoteIPs.count ?? 0
            return "\(rule.processName)(\(rule.mode.shortTitle):\(n)IP)"
        }.joined(separator: ", ")

        let summary =
            "默认:\(globalDefault.shortTitle) · 进程规则: \(matchedApps.isEmpty ? "无" : matchedApps) · VPN \(vpnN) · 本地 \(localN)"

        try await engine.sync(targets: targets, network: net)
        appliedRoutes = await engine.currentApplied()
        return SyncResult(ipCount: ipCount, summary: summary)
    }

    func appIcon(for item: ProcessItem) -> NSImage {
        if let path = item.path, !path.isEmpty {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: UTType.application)
    }
}

import Foundation
import AppKit
import Combine
import Network
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
    private var processRefreshTask: Task<Void, Never>?
    private var networkRefreshTask: Task<Void, Never>?
    private var isRefreshRunning = false
    private var didStart = false
    private var didInitialRouteApply = false
    private var terminateObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    /// 上一轮是否检测到 VPN，用于边沿触发（断开时清路由 + 恢复默认网关）
    private var lastVPNAvailable: Bool = false
    private var lastDefaultRestoreAt: Date = .distantPast
    private var lastNetworkFingerprint: String = ""

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
        startPathMonitor()

        // 启动时只提权一次；之后改规则 / 定时同步都不再弹密码
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await preparePrivilegeAndApplyIfNeeded()
        }

        // 网络状态：2 秒快扫（识别 OpenVPN 连接/断开，不跑 lsof）
        networkRefreshTask?.cancel()
        networkRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshNetworkOnly(reason: "定时网络扫描")
            }
        }

        // 进程列表：5 秒全量刷新（串行，避免重叠丢状态）
        processRefreshTask?.cancel()
        processRefreshTask = Task { [weak self] in
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

    /// 系统路径变化（含 VPN 接口 up/down）时立刻重扫网络
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                // 路径变化后稍等接口/路由写完（OpenVPN Connect 建 utun 需要一瞬）
                try? await Task.sleep(nanoseconds: 400_000_000)
                await self?.refreshNetworkOnly(reason: "网络路径变化")
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self?.refreshNetworkOnly(reason: "网络路径变化-复核")
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
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
        processRefreshTask?.cancel()
        processRefreshTask = nil
        networkRefreshTask?.cancel()
        networkRefreshTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        try? await engine.clearAll()
        await PrivilegeSession.shared.shutdownHelper()
    }

    /// 仅刷新网络快照（快），用于 VPN 连接/断开识别
    private func refreshNetworkOnly(reason: String) async {
        let net = await Task.detached(priority: .utility) {
            NetworkInterfaceManager.snapshot()
        }.value

        let fingerprint = networkFingerprint(net)
        let changed = fingerprint != lastNetworkFingerprint
        let vpnWas = lastVPNAvailable
        network = net
        lastNetworkFingerprint = fingerprint

        if !isBusy {
            let withConn = processes.filter { $0.connectionCount > 0 }.count
            let defMark = net.defaultRouteMissing ? " · 默认路由缺失" : ""
            statusMessage =
                "进程 \(processes.count) · 有连接 \(withConn) · VPN \(net.vpnAvailable ? "✓" : "✗") · 本地 \(net.localAvailable ? "✓" : "✗")\(defMark)"
        }

        await handleNetworkHealth(net, silent: true)

        // VPN 从无→有：立刻按规则写路由（不必等 5s 全量刷新 / 不必重启）
        let vpnRose = !vpnWas && net.vpnAvailable
        if vpnRose {
            statusMessage = "已识别 VPN：\(net.vpnSummary)"
            if hasActiveRules {
                didInitialRouteApply = true
                await syncRoutes(silent: true, reason: "VPN 已连接")
            }
        } else if changed && hasActiveRules && didInitialRouteApply {
            await syncRoutes(silent: true, reason: reason)
        }
    }

    private func networkFingerprint(_ net: NetworkSnapshot) -> String {
        [
            net.vpnAvailable ? "1" : "0",
            net.vpnInterface ?? "",
            net.vpnGateway ?? "",
            net.localGateway ?? "",
            net.defaultGateway ?? "",
            net.defaultRouteMissing ? "1" : "0",
            net.isVPNDefault ? "1" : "0"
        ].joined(separator: "|")
    }

    func refreshAll() {
        // 串行：上一次未完成则跳过，避免 generation 丢弃导致 VPN 状态永远不更新
        guard !isRefreshRunning else { return }
        isRefreshRunning = true
        let includeSys = includeSystem
        let shouldSync = hasActiveRules && didInitialRouteApply
        isRefreshing = true

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isRefreshRunning = false
                    self.isRefreshing = false
                }
            }

            let (net, list) = await Task.detached(priority: .userInitiated) {
                let net = NetworkInterfaceManager.snapshot()
                let list = ProcessMonitor.listProcesses(includeSystem: includeSys)
                return (net, list)
            }.value

            let vpnWas = self.lastVPNAvailable
            self.network = net
            self.processes = list
            self.lastNetworkFingerprint = self.networkFingerprint(net)

            let withConn = list.filter { $0.connectionCount > 0 }.count
            if !self.isBusy {
                let defMark = net.defaultRouteMissing ? " · 默认路由缺失" : ""
                self.statusMessage =
                    "进程 \(list.count) · 有连接 \(withConn) · VPN \(net.vpnAvailable ? "✓" : "✗") · 本地 \(net.localAvailable ? "✓" : "✗")\(defMark)"
            }

            await self.handleNetworkHealth(net, silent: true)

            let vpnRose = !vpnWas && net.vpnAvailable
            if vpnRose {
                self.statusMessage = "已识别 VPN：\(net.vpnSummary)"
            }

            if shouldSync || (vpnRose && self.hasActiveRules) {
                if vpnRose { self.didInitialRouteApply = true }
                await self.syncRoutes(silent: true, reason: vpnRose ? "VPN 已连接" : "定时同步")
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

            // 默认网关丢失时：即使用户无分流规则，也尝试提权恢复
            if net.defaultRouteMissing {
                if !(await PrivilegeSession.shared.isReady()) {
                    do {
                        try await PrivilegeSession.shared.ensurePrivileged()
                        privilegeReady = true
                    } catch {
                        lastError = error.localizedDescription
                        statusMessage = "默认网关缺失，授权失败无法自动恢复"
                        return
                    }
                }
                await handleNetworkHealth(net, silent: false)
            }

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
            } else if !net.defaultRouteMissing {
                statusMessage = "已刷新 · 进程 \(list.count) · 当前跟随系统（无强制路由）"
            }
        }
    }

    // MARK: - 网络健康（VPN 断开 / 默认网关）

    /// VPN 从有→无，或检测到默认路由缺失时：清 VPN 主机路由并尝试恢复本机 default
    private func handleNetworkHealth(_ net: NetworkSnapshot, silent: Bool) async {
        let vpnNow = net.vpnAvailable
        let vpnDropped = lastVPNAvailable && !vpnNow
        lastVPNAvailable = vpnNow

        let needRestore = net.defaultRouteMissing || vpnDropped
        guard needRestore else { return }

        // 未提权时无法改路由表；有规则时用户通常已授权
        guard await PrivilegeSession.shared.isReady() else {
            if !silent && net.defaultRouteMissing {
                statusMessage = "默认网关缺失，授权后将自动恢复"
            }
            return
        }

        // 限流：避免 5s 刷新时反复 delete/add default
        let now = Date()
        let recentlyRestored = now.timeIntervalSince(lastDefaultRestoreAt) < 8

        do {
            if vpnDropped {
                try await engine.clearVPNRoutes()
                appliedRoutes = await engine.currentApplied()
            }

            if net.defaultRouteMissing && !recentlyRestored {
                let restored = try await engine.restoreDefaultRouteIfNeeded(network: net)
                if restored {
                    lastDefaultRestoreAt = now
                    // 恢复后再读一次网络状态
                    let refreshed = await Task.detached(priority: .utility) {
                        NetworkInterfaceManager.snapshot()
                    }.value
                    network = refreshed
                    lastVPNAvailable = refreshed.vpnAvailable
                    if !silent || vpnDropped {
                        statusMessage =
                            "已恢复本机默认网关 \(refreshed.localGateway ?? net.localGateway ?? "")"
                    }
                }
            } else if vpnDropped, !silent {
                statusMessage = "VPN 已断开，已清除 VPN 主机路由"
            }
        } catch {
            if !silent {
                lastError = "恢复网络失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 路由同步

    private func syncRoutes(silent: Bool, reason: String) async {
        if !silent { isBusy = true }
        defer { if !silent { isBusy = false } }

        // 每次同步前先处理 VPN 断开 / 默认网关
        let preNet = await Task.detached(priority: .utility) {
            NetworkInterfaceManager.snapshot()
        }.value
        network = preNet
        await handleNetworkHealth(preNet, silent: silent)

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

        // VPN 不可用时：不再硬失败卡死；清掉 VPN 路由，仅保留仍可执行的 local 规则
        if needsVPN && !net.vpnAvailable {
            try await engine.clearVPNRoutes()
            appliedRoutes = await engine.currentApplied()
            // 若只需要 VPN、没有 local 规则，给出提示后返回
            if !needsLocal {
                return SyncResult(
                    ipCount: 0,
                    summary: "VPN 已断开，已清除 VPN 主机路由；等待 VPN 重连"
                )
            }
        }
        if needsLocal && !net.localAvailable {
            throw AppError.noLocalGateway
        }

        // 构建目标时：VPN 不可用则把 defaultMode/规则中的 vpn 当作暂不可用
        let effectiveDefault: RouteMode = {
            if globalDefault == .vpn && !net.vpnAvailable { return .system }
            return globalDefault
        }()
        let effectiveRules: [RouteRule] = currentRules.map { r in
            var copy = r
            if r.mode == .vpn && !net.vpnAvailable {
                copy.enabled = false
            }
            return copy
        }

        let targets = ProcessMonitor.remoteIPs(
            matching: effectiveRules,
            processes: list,
            defaultMode: effectiveDefault
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

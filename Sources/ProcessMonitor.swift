import Foundation
import AppKit
import Darwin

/// 枚举运行中「应用」及其网络连接。
/// 同一 App（含多窗口 / Helper / Renderer）合并为一行，按 Bundle ID 匹配规则。
enum ProcessMonitor {
    nonisolated static func listProcesses(includeSystem: Bool = false) -> [ProcessItem] {
        let connections = loadConnections()
        var ipsByPID: [Int32: Set<String>] = [:]
        var vpnBoundByPID: [Int32: Set<String>] = [:]
        var networkPIDs: Set<Int32> = []
        for c in connections {
            ipsByPID[c.pid, default: []].insert(c.remoteIP)
            if c.isVPNBound {
                vpnBoundByPID[c.pid, default: []].insert(c.remoteIP)
            }
            // 有外连的 pid 都可能是网络进程
            networkPIDs.insert(c.pid)
        }

        var pathByPID: [Int32: String] = [:]
        // 预先解析有连接的 pid + 所有前台 app 的 pid 路径
        var pidsToResolve = Set(ipsByPID.keys)
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.processIdentifier > 0 {
                pidsToResolve.insert(app.processIdentifier)
            }
        }
        for pid in pidsToResolve {
            if let p = processPath(pid: pid) {
                pathByPID[pid] = p
            }
        }
        // Chrome Helper 等沙箱进程 proc_pidpath 常失败：批量用 ps 补路径
        fillMissingPathsFromPS(into: &pathByPID, pids: pidsToResolve)

        // key = 稳定 matchKey（优先 Bundle ID）
        struct Acc {
            var name: String
            var matchKey: String
            var path: String?
            var isApp: Bool
            var pids: Set<Int32>
            var ips: Set<String>
            var vpnBoundIPs: Set<String>
            var netPIDs: Set<Int32>
            var policy: NSApplication.ActivationPolicy
        }
        var byKey: [String: Acc] = [:]
        var claimedPIDs = Set<Int32>()

        // 先登记所有「正式 App」，再把包内进程合并进来
        // WPS 等：SharedSupport 下嵌套多个 .app（wpscloudsvr 等），必须归到最外层产品包
        for app in runningApps {
            let pid = app.processIdentifier
            if pid <= 0 { continue }

            let name = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? "App"
            let bundleID = app.bundleIdentifier ?? ""
            let bundlePath = app.bundleURL?.path
            let path = bundlePath ?? app.executableURL?.path
            // 嵌套 .app 一律用最外层包身份（解决 WPS 多进程拆行）
            let matchKey = normalizeMatchKey(bundleID: bundleID, path: path, name: name)
            let displayPath = outermostAppBundlePath(from: path) ?? path
            let policy = app.activationPolicy

            // Helper 类附属进程（无独立 .app 展示名）不单独占一行：
            // 若路径落在某个主 App 包内，后面会并进去；这里跳过 prohibited 且无 bundle 的
            if policy == .prohibited, bundlePath == nil {
                continue
            }

            var acc = byKey[matchKey] ?? Acc(
                name: name,
                matchKey: matchKey,
                path: displayPath,
                isApp: true,
                pids: [],
                ips: [],
                vpnBoundIPs: [],
                netPIDs: [],
                policy: policy
            )
            // 保留更「主」的名字（regular 优先）；主程序路径优先
            if policy == .regular {
                acc.name = preferredProductName(outerPath: displayPath, fallback: name)
                acc.policy = .regular
                acc.path = displayPath ?? acc.path
            } else if acc.policy != .regular {
                // 附属进程不覆盖主名
                if acc.name.isEmpty { acc.name = name }
            }
            acc.pids.insert(pid)
            if let ips = ipsByPID[pid] {
                acc.ips.formUnion(ips)
            }
            if let vb = vpnBoundByPID[pid] {
                acc.vpnBoundIPs.formUnion(vb)
            }
            if networkPIDs.contains(pid) {
                acc.netPIDs.insert(pid)
            }
            claimedPIDs.insert(pid)
            byKey[matchKey] = acc
        }

        // 把所有落在 .app 包内的进程（含 Helper / 嵌套 .app）并入最外层产品
        // outerRoot → matchKey（始终指向最外层）
        var outerRootToKey: [String: String] = [:]
        for (key, acc) in byKey {
            if let p = acc.path, let outer = outermostAppBundlePath(from: p) {
                outerRootToKey[outer] = key
            }
        }
        for app in runningApps {
            guard let root = app.bundleURL?.path else { continue }
            let outer = outermostAppBundlePath(from: root) ?? root
            let bid = app.bundleIdentifier ?? ""
            let key = normalizeMatchKey(
                bundleID: bid,
                path: root,
                name: app.localizedName ?? root
            )
            outerRootToKey[outer] = key
            if byKey[key] == nil {
                byKey[key] = Acc(
                    name: preferredProductName(outerPath: outer, fallback: app.localizedName ?? URL(fileURLWithPath: outer).deletingPathExtension().lastPathComponent),
                    matchKey: key,
                    path: outer,
                    isApp: true,
                    pids: [],
                    ips: [],
                    vpnBoundIPs: [],
                    netPIDs: [],
                    policy: app.activationPolicy
                )
            }
        }

        for (pid, helperPath) in pathByPID {
            guard let outer = outermostAppBundlePath(from: helperPath) else { continue }
            let key: String
            if let existing = outerRootToKey[outer] {
                key = existing
            } else {
                let bid = bundleIdentifier(atAppRoot: outer) ?? ""
                key = normalizeMatchKey(
                    bundleID: bid,
                    path: outer,
                    name: URL(fileURLWithPath: outer).deletingPathExtension().lastPathComponent
                )
                outerRootToKey[outer] = key
                if byKey[key] == nil {
                    byKey[key] = Acc(
                        name: preferredProductName(outerPath: outer, fallback: URL(fileURLWithPath: outer).deletingPathExtension().lastPathComponent),
                        matchKey: key,
                        path: outer,
                        isApp: true,
                        pids: [],
                        ips: [],
                        vpnBoundIPs: [],
                        netPIDs: [],
                        policy: .regular
                    )
                }
            }
            var acc = byKey[key]!
            acc.pids.insert(pid)
            if let ips = ipsByPID[pid] {
                acc.ips.formUnion(ips)
            }
            if let vb = vpnBoundByPID[pid] {
                acc.vpnBoundIPs.formUnion(vb)
            }
            if networkPIDs.contains(pid) {
                acc.netPIDs.insert(pid)
            }
            acc.path = outer
            byKey[key] = acc
            claimedPIDs.insert(pid)
        }

        // 二次折叠：同一最外层 .app 若仍被拆成多行（不同 Bundle ID），合并为一
        // （WPS：主程序 com.kingsoft.* + 云服务 cn.wps.wpscloudsvr 等）
        do {
            var groups: [String: [String]] = [:]
            for (key, acc) in byKey {
                let outer = outermostAppBundlePath(from: acc.path) ?? key
                groups[outer, default: []].append(key)
            }
            var collapsed: [String: Acc] = [:]
            for (outer, keys) in groups {
                var merged: Acc?
                for k in keys {
                    guard let acc = byKey[k] else { continue }
                    if merged == nil {
                        merged = acc
                        continue
                    }
                    var m = merged!
                    m.pids.formUnion(acc.pids)
                    m.ips.formUnion(acc.ips)
                    m.vpnBoundIPs.formUnion(acc.vpnBoundIPs)
                    m.netPIDs.formUnion(acc.netPIDs)
                    if acc.policy == .regular {
                        m.policy = .regular
                        m.name = preferredProductName(outerPath: outer, fallback: acc.name)
                    }
                    merged = m
                }
                guard var m = merged else { continue }
                m.path = outer
                m.isApp = true
                m.name = preferredProductName(outerPath: outer, fallback: m.name)
                let canonical = normalizeMatchKey(bundleID: "", path: outer, name: m.name)
                m.matchKey = canonical
                // 若 canonical 已存在（另一 outer 冲突极少见），再合并
                if var existing = collapsed[canonical] {
                    existing.pids.formUnion(m.pids)
                    existing.ips.formUnion(m.ips)
                    existing.vpnBoundIPs.formUnion(m.vpnBoundIPs)
                    existing.netPIDs.formUnion(m.netPIDs)
                    if m.policy == .regular { existing.policy = .regular; existing.name = m.name }
                    collapsed[canonical] = existing
                } else {
                    collapsed[canonical] = m
                }
            }
            byKey = collapsed
        }

        // 剩余无包归属的进程（命令行等）
        // 先建：已知 App 的 PID → matchKey，便于按父进程挂靠
        var pidToKey: [Int32: String] = [:]
        for (key, acc) in byKey {
            for p in acc.pids { pidToKey[p] = key }
        }

        for (pid, ips) in ipsByPID where !claimedPIDs.contains(pid) {
            if !includeSystem && pid < 50 { continue }
            let path = pathByPID[pid]
            // 再尝试一次 .app 归属（path 可能刚解析到）
            if let path, let root = outermostAppBundlePath(from: path) {
                let bid = bundleIdentifier(atAppRoot: root) ?? ""
                let key = normalizeMatchKey(
                    bundleID: bid,
                    path: root,
                    name: URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
                )
                var acc = byKey[key] ?? Acc(
                    name: preferredProductName(outerPath: root, fallback: URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent),
                    matchKey: key,
                    path: root,
                    isApp: true,
                    pids: [],
                    ips: [],
                    vpnBoundIPs: [],
                    netPIDs: [],
                    policy: .regular
                )
                acc.pids.insert(pid)
                acc.ips.formUnion(ips)
                if let vb = vpnBoundByPID[pid] { acc.vpnBoundIPs.formUnion(vb) }
                if networkPIDs.contains(pid) { acc.netPIDs.insert(pid) }
                byKey[key] = acc
                pidToKey[pid] = key
                claimedPIDs.insert(pid)
                continue
            }

            // 按父进程链挂靠（Chrome Helper 沙箱无 path 时常见）
            if let parentKey = resolveKeyViaParent(pid: pid, pidToKey: pidToKey) {
                var acc = byKey[parentKey]!
                acc.pids.insert(pid)
                acc.ips.formUnion(ips)
                if let vb = vpnBoundByPID[pid] { acc.vpnBoundIPs.formUnion(vb) }
                if networkPIDs.contains(pid) { acc.netPIDs.insert(pid) }
                byKey[parentKey] = acc
                claimedPIDs.insert(pid)
                continue
            }

            // 命令名启发式：Chrome Helper / Codex / Computer Use → 并入主应用行
            let cmd = processCommandName(pid: pid)?.lowercased() ?? ""
            let argsHint = (pathByPID[pid] ?? "").lowercased()
            if let chromeKey = byKey.keys.first(where: {
                $0 == "com.google.Chrome" || $0.lowercased().contains("chrome")
            }), cmd.hasPrefix("google") || cmd.contains("chrome") {
                var acc = byKey[chromeKey]!
                acc.pids.insert(pid)
                acc.ips.formUnion(ips)
                if let vb = vpnBoundByPID[pid] { acc.vpnBoundIPs.formUnion(vb) }
                if networkPIDs.contains(pid) { acc.netPIDs.insert(pid) }
                byKey[chromeKey] = acc
                claimedPIDs.insert(pid)
                continue
            }
            if cmd.contains("chatgpt") || cmd.contains("codex") || cmd.contains("skycomputeruse")
                || cmd.contains("computer use") || argsHint.contains("chatgpt")
                || argsHint.contains("computer-use") || argsHint.contains("codex")
            {
                let family = "com.openai.codex"
                var acc = byKey[family] ?? Acc(
                    name: "ChatGPT",
                    matchKey: family,
                    path: "/Applications/ChatGPT.app",
                    isApp: true,
                    pids: [],
                    ips: [],
                    vpnBoundIPs: [],
                    netPIDs: [],
                    policy: .regular
                )
                acc.pids.insert(pid)
                acc.ips.formUnion(ips)
                if let vb = vpnBoundByPID[pid] { acc.vpnBoundIPs.formUnion(vb) }
                if networkPIDs.contains(pid) { acc.netPIDs.insert(pid) }
                byKey[family] = acc
                claimedPIDs.insert(pid)
                continue
            }

            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid-\(pid)"
            let matchKey = path ?? name
            // 同路径合并
            var acc = byKey[matchKey] ?? Acc(
                name: name,
                matchKey: matchKey,
                path: path,
                isApp: false,
                pids: [],
                ips: [],
                vpnBoundIPs: [],
                netPIDs: [],
                policy: .prohibited
            )
            acc.pids.insert(pid)
            acc.ips.formUnion(ips)
            if let vb = vpnBoundByPID[pid] { acc.vpnBoundIPs.formUnion(vb) }
            if networkPIDs.contains(pid) { acc.netPIDs.insert(pid) }
            byKey[matchKey] = acc
        }

        var items: [ProcessItem] = []
        for (_, acc) in byKey {
            if !includeSystem {
                if acc.policy == .prohibited && acc.ips.isEmpty && !acc.isApp { continue }
                if acc.matchKey.hasPrefix("com.apple."),
                   acc.policy != .regular,
                   acc.ips.isEmpty
                {
                    continue
                }
            }
            // 代表 pid：取最小的（通常主进程更靠前）
            let repPID = acc.pids.min() ?? 0
            let ipList = Array(acc.ips).sorted()
            items.append(
                ProcessItem(
                    pid: repPID,
                    name: acc.name,
                    matchKey: acc.matchKey,
                    path: acc.path,
                    isApp: acc.isApp,
                    connectionCount: ipList.count,
                    remoteIPs: ipList,
                    vpnBoundRemoteIPs: Array(acc.vpnBoundIPs).sorted(),
                    networkPIDs: Array(acc.netPIDs).sorted()
                )
            )
        }

        return items.sorted { a, b in
            if a.connectionCount != b.connectionCount {
                return a.connectionCount > b.connectionCount
            }
            if a.isApp != b.isApp { return a.isApp && !b.isApp }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// 收集目标 IP。进程级规则优先；无规则时使用 `defaultMode`。
    nonisolated static func remoteIPs(
        matching rules: [RouteRule],
        processes: [ProcessItem],
        defaultMode: RouteMode = .system
    ) -> [RouteMode: [(ip: String, processName: String)]] {
        var result: [RouteMode: [(ip: String, processName: String)]] = [.vpn: [], .local: []]
        let enabled = rules.filter { $0.enabled && $0.mode != .system }
        var claimedIP = Set<String>()

        func append(mode: RouteMode, ip: String, name: String) {
            guard mode == .vpn || mode == .local else { return }
            if claimedIP.contains(ip) { return }
            claimedIP.insert(ip)
            result[mode, default: []].append((ip, name))
        }

        for process in processes {
            guard let rule = enabled.first(where: { matches($0, process: process) }) else { continue }
            for ip in process.remoteIPs {
                append(mode: rule.mode, ip: ip, name: process.name)
            }
        }

        if defaultMode == .vpn || defaultMode == .local {
            for process in processes {
                if enabled.contains(where: { matches($0, process: process) }) { continue }
                for ip in process.remoteIPs {
                    append(mode: defaultMode, ip: ip, name: process.name)
                }
            }
        }

        return result
    }

    /// 按「应用」匹配：Bundle ID、.app 包路径、显示名（含 Helper 前缀）
    nonisolated static func matches(_ rule: RouteRule, process: ProcessItem) -> Bool {
        if process.matchKey == rule.matchKey { return true }

        // 产品族互认（ChatGPT ↔ Computer Use）
        let ruleFamily = productFamilyKey(
            bundleID: rule.matchKey,
            path: nil,
            name: rule.processName
        )
        let procFamily = productFamilyKey(
            bundleID: process.matchKey,
            path: process.path,
            name: process.name
        )
        if let rf = ruleFamily, let pf = procFamily, rf == pf {
            return true
        }
        if let rf = ruleFamily, process.matchKey == rf { return true }
        if let pf = procFamily, rule.matchKey == pf { return true }

        // Bundle ID 互认
        if isBundleID(rule.matchKey), process.matchKey == rule.matchKey {
            return true
        }

        // 显示名：Google Chrome / Google Chrome Helper...
        if namesBelongToSameApp(rule.processName, process.name) {
            return true
        }
        if process.name.caseInsensitiveCompare(rule.processName) == .orderedSame {
            return true
        }

        guard let path = process.path else { return false }

        if path == rule.matchKey { return true }

        // 规则存的是 .app 路径
        if rule.matchKey.hasSuffix(".app") {
            if path == rule.matchKey || path.hasPrefix(rule.matchKey + "/") {
                return true
            }
        }

        // 进程在某 .app 内，与规则 Bundle ID / 名对应
        if let root = appBundleRoot(from: path) {
            if rule.matchKey == root || path.hasPrefix(rule.matchKey) && rule.matchKey.contains(".app") {
                return true
            }
            if isBundleID(rule.matchKey),
               let bid = bundleIdentifier(atAppRoot: root),
               bid == rule.matchKey
            {
                return true
            }
            let appLabel = URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
            if namesBelongToSameApp(rule.processName, appLabel) {
                return true
            }
        }

        let base = URL(fileURLWithPath: path).lastPathComponent
        if base == rule.processName || base == rule.matchKey { return true }
        if namesBelongToSameApp(rule.processName, base) { return true }

        return false
    }

    // MARK: - App identity helpers

    /// 稳定 matchKey：最外层 .app Bundle ID，再套产品族（ChatGPT+Computer Use 等）
    nonisolated static func normalizeMatchKey(bundleID: String, path: String?, name: String) -> String {
        if let path, let outer = outermostAppBundlePath(from: path) {
            let outerBid = bundleIdentifier(atAppRoot: outer) ?? ""
            if let family = productFamilyKey(
                bundleID: outerBid.isEmpty ? bundleID : outerBid,
                path: path,
                name: name
            ) {
                return family
            }
            if !outerBid.isEmpty {
                return outerBid
            }
            // 嵌套包：归到外层路径，避免拆行
            if path.hasPrefix(outer + "/") || path == outer {
                return outer
            }
        }
        if let family = productFamilyKey(bundleID: bundleID, path: path, name: name) {
            return family
        }
        if !bundleID.isEmpty { return bundleID }
        if let path, let root = appBundleRoot(from: path) {
            if let bid = bundleIdentifier(atAppRoot: root), !bid.isEmpty {
                if let family = productFamilyKey(bundleID: bid, path: path, name: name) {
                    return family
                }
                return bid
            }
            return root
        }
        if let path, !path.isEmpty { return path }
        return name
    }

    // MARK: 产品族 / 通用合并规则
    //
    // 两层策略：
    // 1) **通用规则**（所有产品自动生效，见 normalizeMatchKey / 折叠 / 父进程）
    //    - 同一最外层 .app 包内的嵌套进程 → 一行（WPS SharedSupport、Chrome Helper…）
    //    - Bundle ID 以 helper/service/agent/… 结尾 → 归到去掉后缀的主 ID
    //    - 沙箱读不到路径 → ps 补路径 + 父进程 PPID 挂靠
    //    - 显示名去掉 Helper/Renderer/Service 等后缀后相同 → 视为同一应用
    // 2) **产品族表**（跨独立安装包、不同 Bundle ID 的套件，如 ChatGPT + Computer Use）
    //    - 仅当通用规则不够时追加；新套件往 `productFamilies` 加一项即可

    /// 可扩展产品族：canonicalKey 为列表里统一 matchKey
    private struct ProductFamily: Sendable {
        let canonicalKey: String
        let displayName: String
        /// Bundle ID 前缀（小写，hasPrefix）
        let bundlePrefixes: [String]
        /// 精确 Bundle ID（小写）
        let bundleIDs: [String]
        /// 路径子串（小写）
        let pathContains: [String]
        /// 名称子串（小写）
        let nameContains: [String]
    }

    /// 跨包套件表。通用规则搞不定时再加这里（不要把 Word/Excel 这类故意分开的产品写进来）。
    nonisolated private static let productFamilies: [ProductFamily] = [
        ProductFamily(
            canonicalKey: "com.openai.codex",
            displayName: "ChatGPT",
            bundlePrefixes: [
                "com.openai.codex",
                "com.openai.chatgpt",
                "com.openai.sky"
            ],
            bundleIDs: [
                "com.openai.sky.cuaservice"
            ],
            pathContains: [
                "/chatgpt.app",
                "codex computer use.app",
                "/.codex/computer-use/",
                "/contents/resources/codex",
                "codex framework.framework"
            ],
            nameContains: [
                "chatgpt",
                "codex computer use",
                "computer use",
                "skycomputeruse"
            ]
        )
        // 以后例如：
        // ProductFamily(canonicalKey: "com.example.suite", displayName: "Example", ...)
    ]

    /// 产品族归并（套件表 + 通用 helper 后缀）
    nonisolated static func productFamilyKey(bundleID: String, path: String?, name: String) -> String? {
        let bid = bundleID.lowercased()
        let n = name.lowercased()
        let p = (path ?? "").lowercased()

        for fam in productFamilies {
            if fam.bundleIDs.contains(bid) { return fam.canonicalKey }
            if fam.bundlePrefixes.contains(where: { bid == $0 || bid.hasPrefix($0 + ".") }) {
                return fam.canonicalKey
            }
            if fam.pathContains.contains(where: { p.contains($0) }) {
                return fam.canonicalKey
            }
            if fam.nameContains.contains(where: { n == $0 || n.contains($0) }) {
                return fam.canonicalKey
            }
        }

        // 通用：com.foo.bar.helper / .service / .agent → com.foo.bar
        if let stripped = stripHelperBundleSuffix(bid), stripped != bid {
            return stripped
        }
        return nil
    }

    /// Bundle ID 组件后缀：附属进程 → 主产品 ID
    nonisolated private static func stripHelperBundleSuffix(_ bid: String) -> String? {
        let parts = bid.split(separator: ".").map(String.init)
        guard parts.count >= 4 else { return nil } // 至少 com.vendor.product.component
        let last = parts[parts.count - 1].lowercased()
        let tokens: Set<String> = [
            "helper", "helpers", "service", "agent", "renderer", "plugin",
            "gpu", "updater", "launcher", "extension", "widget", "monitor",
            "daemon", "worker", "broker", "loginhelper", "docktile",
            "xpcservice", "appex"
        ]
        // 完整命中，或 *service / *helper 后缀（cuaservice 等）
        let dropLast =
            tokens.contains(last)
            || last.hasSuffix("service")
            || last.hasSuffix("helper")
            || last.hasSuffix("agent")
            || last.hasSuffix("plugin")
            || last.hasSuffix("renderer")
        guard dropLast else { return nil }
        return parts.dropLast().joined(separator: ".")
    }

    nonisolated private static func displayNameForFamilyKey(_ key: String) -> String? {
        productFamilies.first(where: { $0.canonicalKey == key })?.displayName
    }

    nonisolated static func isBundleID(_ s: String) -> Bool {
        // com.google.Chrome 等
        s.contains(".") && !s.contains("/") && !s.hasSuffix(".app")
    }

    /// 最外层 .app（与 appBundleRoot 相同，语义更明确）
    nonisolated static func outermostAppBundlePath(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return appBundleRoot(from: path)
    }

    /// 产品显示名：优先产品族表 → Info.plist → 包名
    nonisolated static func preferredProductName(outerPath: String?, fallback: String) -> String {
        let bid = outerPath.flatMap { bundleIdentifier(atAppRoot: $0) } ?? ""
        if let family = productFamilyKey(bundleID: bid, path: outerPath, name: fallback),
           let dn = displayNameForFamilyKey(family)
        {
            return dn
        }
        guard let outerPath else { return fallback }
        let base = URL(fileURLWithPath: outerPath).deletingPathExtension().lastPathComponent
        let lower = base.lowercased()
        // 常见安装目录名（非套件、仅显示）
        if lower == "wpsoffice" || lower == "wps office" { return "WPS Office" }
        let info = URL(fileURLWithPath: outerPath).appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: info) as? [String: Any] {
            let ib = (dict["CFBundleIdentifier"] as? String) ?? ""
            if let family = productFamilyKey(bundleID: ib, path: outerPath, name: fallback),
               let dn = displayNameForFamilyKey(family)
            {
                return dn
            }
            if let dn = dict["CFBundleDisplayName"] as? String, !dn.isEmpty { return dn }
            if let bn = dict["CFBundleName"] as? String, !bn.isEmpty { return bn }
        }
        return base.isEmpty ? fallback : base
    }

    /// 从任意可执行路径提取最外层 .app 根路径
    nonisolated static func appBundleRoot(from path: String) -> String? {
        // /Applications/wpsoffice.app/Contents/SharedSupport/wpscloudsvr.app/...
        // → /Applications/wpsoffice.app
        var url = URL(fileURLWithPath: path)
        var found: String?
        while url.path != "/" {
            if url.pathExtension == "app" {
                found = url.path
                // 继续向上，取最外层
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return found
    }

    nonisolated static func bundleIdentifier(atAppRoot root: String) -> String? {
        let info = URL(fileURLWithPath: root).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    /// 通用显示名归并：主程序 vs Helper/Service/Renderer…
    nonisolated static func namesBelongToSameApp(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty || y.isEmpty { return false }
        if x.caseInsensitiveCompare(y) == .orderedSame { return true }

        let xl = x.lowercased()
        let yl = y.lowercased()

        // 产品族表名称
        if let fa = productFamilyKey(bundleID: "", path: nil, name: xl),
           let fb = productFamilyKey(bundleID: "", path: nil, name: yl),
           fa == fb
        {
            return true
        }

        // 去掉附属角色词再比（通用，不绑品牌）
        func stem(_ s: String) -> String {
            var t = s
            let suffixes = [
                " helper (renderer)", " helper (gpu)", " helper (plugin)",
                " helper", " renderer", " (renderer)", " (gpu)", " (plugin)",
                " (service)", " service", " agent", " backend", " cloud",
                " updater", " launcher", " computer use", " network service"
            ]
            for suf in suffixes {
                if t.hasSuffix(suf) {
                    t = String(t.dropLast(suf.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            return t
        }
        let xs = stem(xl)
        let ys = stem(yl)
        if xs == ys, xs.count >= 3 { return true }
        if xs.hasPrefix(ys) || ys.hasPrefix(xs) {
            return min(xs.count, ys.count) >= 4
        }
        return false
    }

    // MARK: - Connections

    private struct Conn {
        let pid: Int32
        let command: String
        let remoteIP: String
        let localIP: String?
        /// 本端地址落在 VPN 隧道（如 10.8.0.10）→ 连接仍走代理
        let isVPNBound: Bool
    }

    /// 当前 VPN 接口上的 IPv4（用于判断连接是否绑在隧道上）
    nonisolated private static func vpnInterfaceIPv4s() -> Set<String> {
        guard let out = try? Shell.run("/sbin/ifconfig", timeout: 5, requireZeroExit: false) else {
            return []
        }
        var result = Set<String>()
        var current: String?
        var currentIsVPN = false
        for line in out.split(separator: "\n").map(String.init) {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                current = line.split(separator: ":").first.map(String.init)
                let n = current ?? ""
                currentIsVPN = n.hasPrefix("utun") || n.hasPrefix("ipsec")
                    || n.hasPrefix("ppp") || n.hasPrefix("wg")
                continue
            }
            guard currentIsVPN else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let ip = parts[1]
            if isIPv4Literal(ip), ip != "127.0.0.1" {
                result.insert(ip)
            }
        }
        return result
    }

    nonisolated private static func loadConnections() -> [Conn] {
        // TCP 全部状态 + UDP（Chrome HTTP/3 QUIC 走 UDP/443）
        // 不用 -sTCP:ESTABLISHED：否则看不到新建连接，且漏掉大量已建立外的状态
        let cmd = "/usr/sbin/lsof -nP -iTCP -iUDP 2>/dev/null"
        guard let out = try? Shell.run(cmd, timeout: 35, requireZeroExit: false),
              !out.isEmpty
        else {
            return []
        }

        let vpnIPs = vpnInterfaceIPv4s()
        var list: [Conn] = []
        var seen = Set<String>() // pid|remote

        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("COMMAND") || line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 8 else { continue }
            let command = parts[0]
            guard let pid = Int32(parts[1]) else { continue }

            let name: String
            if let idx = parts.firstIndex(of: "TCP") ?? parts.firstIndex(of: "UDP") {
                name = parts[(idx + 1)...].joined(separator: " ")
            } else {
                name = parts.last ?? ""
            }

            // 只要有远端（含 UDP QUIC）
            guard name.contains("->") else { continue }
            guard let remote = extractRemoteIP(from: name) else { continue }
            let local = extractLocalIP(from: name)
            let key = "\(pid)|\(remote)"
            if seen.contains(key) { continue }
            seen.insert(key)

            let vpnBound: Bool = {
                guard let local, isIPv4Literal(local) else { return false }
                if vpnIPs.contains(local) { return true }
                // 常见 OpenVPN 网段兜底
                if local.hasPrefix("10.8.") || local.hasPrefix("10.7.") { return true }
                return false
            }()

            list.append(
                Conn(
                    pid: pid,
                    command: command,
                    remoteIP: remote,
                    localIP: local,
                    isVPNBound: vpnBound
                )
            )
        }
        return list
    }

    /// NAME 字段：`10.8.0.10:65503->104.18.38.128:443 (ESTABLISHED)`
    nonisolated private static func extractLocalIP(from name: String) -> String? {
        guard let range = name.range(of: "->") else { return nil }
        var host = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        if let sp = host.firstIndex(of: " ") {
            host = String(host[..<sp])
        }
        // 去掉 * 或空
        if host == "*" || host.isEmpty { return nil }
        if host.hasPrefix("[") { return nil }
        if let idx = host.lastIndex(of: ":") {
            host = String(host[..<idx])
        }
        host = host.trimmingCharacters(in: .whitespaces)
        return isIPv4Literal(host) ? host : nil
    }

    nonisolated private static func extractRemoteIP(from name: String) -> String? {
        guard let range = name.range(of: "->") else { return nil }
        var host = String(name[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        if let sp = host.firstIndex(of: " ") {
            host = String(host[..<sp])
        }
        if host.hasPrefix("[") { return nil }
        if let idx = host.lastIndex(of: ":") {
            host = String(host[..<idx])
        }
        host = host.trimmingCharacters(in: .whitespaces)
        guard isPublicOrRoutable(host) else { return nil }
        return host
    }

    nonisolated private static func isIPv4Literal(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { (0...255).contains($0) }
    }

    nonisolated private static func isPublicOrRoutable(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 127 { return false }
        if parts[0] == 0 { return false }
        if parts[0] == 255 { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }
        if (224...239).contains(parts[0]) { return false }
        // 不排除 RFC1918：部分内网服务也需要路由；VPN 隧道地址不当目标
        if parts[0] == 10 && parts[1] == 8 { return false }
        return true
    }

    nonisolated private static func processPath(pid: Int32) -> String? {
        processPathForPID(pid)
    }

    nonisolated static func processPathForPID(_ pid: Int32) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(PATH_MAX))
        defer { buf.deallocate() }
        let ret = proc_pidpath(pid, buf, UInt32(PATH_MAX))
        if ret > 0 {
            return String(cString: buf)
        }
        // 沙箱 Helper（Chrome 等）proc_pidpath 常失败，回退 ps
        return processPathFromPS(pid: pid)
    }

    /// `/bin/ps -p PID -o args=`：Chrome 路径含空格，截到 ` --` 之前
    nonisolated private static func processPathFromPS(pid: Int32) -> String? {
        guard let out = try? Shell.run(
            "/bin/ps -p \(pid) -o args= 2>/dev/null",
            timeout: 2,
            requireZeroExit: false
        ) else { return nil }
        return executablePath(fromArgsLine: out)
    }

    nonisolated private static func executablePath(fromArgsLine raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/") else { return nil }
        // 参数都以 " --" 开头（Chrome/Electron）
        if let r = line.range(of: " --") {
            let p = String(line[..<r.lowerBound])
            if p.contains(".app/") { return p }
        }
        if line.contains(".app/") {
            return line
        }
        return nil
    }

    /// 一次 ps 补全多个缺失路径（比逐 pid 调用快）
    nonisolated private static func fillMissingPathsFromPS(
        into pathByPID: inout [Int32: String],
        pids: Set<Int32>
    ) {
        let missing = pids.filter { pathByPID[$0] == nil }
        guard !missing.isEmpty else { return }
        // ps -axo pid=,args= 全表一次
        guard let out = try? Shell.run("/bin/ps -axo pid=,args= 2>/dev/null", timeout: 8, requireZeroExit: false)
        else { return }
        let want = missing
        for line in out.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<sp]), want.contains(pid) else { continue }
            let args = String(trimmed[trimmed.index(after: sp)...])
            if let path = executablePath(fromArgsLine: args) {
                pathByPID[pid] = path
            }
        }
    }

    nonisolated private static func processCommandName(pid: Int32) -> String? {
        guard let out = try? Shell.run(
            "/bin/ps -p \(pid) -o comm= 2>/dev/null",
            timeout: 2,
            requireZeroExit: false
        ) else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 沿 PPID 向上找已登记的应用
    nonisolated private static func resolveKeyViaParent(
        pid: Int32,
        pidToKey: [Int32: String]
    ) -> String? {
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<8 {
            if seen.contains(current) { break }
            seen.insert(current)
            guard let ppid = parentPID(of: current), ppid > 1 else { break }
            if let key = pidToKey[ppid] { return key }
            current = ppid
        }
        return nil
    }

    nonisolated private static func parentPID(of pid: Int32) -> Int32? {
        guard let out = try? Shell.run(
            "/bin/ps -p \(pid) -o ppid= 2>/dev/null",
            timeout: 2,
            requireZeroExit: false
        ) else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(s)
    }
}

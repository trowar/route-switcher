import Foundation
import AppKit
import Darwin

/// 枚举运行中「应用」及其网络连接。
/// 同一 App（含多窗口 / Helper / Renderer）合并为一行，按 Bundle ID 匹配规则。
enum ProcessMonitor {
    nonisolated static func listProcesses(includeSystem: Bool = false) -> [ProcessItem] {
        let connections = loadConnections()
        var ipsByPID: [Int32: Set<String>] = [:]
        for c in connections {
            ipsByPID[c.pid, default: []].insert(c.remoteIP)
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

        // key = 稳定 matchKey（优先 Bundle ID）
        struct Acc {
            var name: String
            var matchKey: String
            var path: String?
            var isApp: Bool
            var pids: Set<Int32>
            var ips: Set<String>
            var policy: NSApplication.ActivationPolicy
        }
        var byKey: [String: Acc] = [:]
        var claimedPIDs = Set<Int32>()

        // 先登记所有「正式 App」，再把包内进程合并进来
        for app in runningApps {
            let pid = app.processIdentifier
            if pid <= 0 { continue }

            let name = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? "App"
            let bundleID = app.bundleIdentifier ?? ""
            let bundlePath = app.bundleURL?.path
            let path = bundlePath ?? app.executableURL?.path
            let matchKey = normalizeMatchKey(bundleID: bundleID, path: path, name: name)
            let policy = app.activationPolicy

            // Helper 类附属进程（无独立 .app 展示名）不单独占一行：
            // 若路径落在某个主 App 包内，后面会并进去；这里跳过 prohibited 且无 bundle 的
            if policy == .prohibited, bundlePath == nil {
                continue
            }

            var acc = byKey[matchKey] ?? Acc(
                name: name,
                matchKey: matchKey,
                path: path,
                isApp: true,
                pids: [],
                ips: [],
                policy: policy
            )
            // 保留更「主」的名字（regular 优先）
            if policy == .regular {
                acc.name = name
                acc.policy = .regular
                acc.path = path ?? acc.path
            } else if acc.policy != .regular {
                acc.name = name
            }
            acc.pids.insert(pid)
            if let ips = ipsByPID[pid] {
                acc.ips.formUnion(ips)
            }
            claimedPIDs.insert(pid)
            byKey[matchKey] = acc
        }

        // 把所有落在 .app 包内的进程（含 Helper）并入对应 App
        // 建立 bundlePath → matchKey 索引
        var bundleRootToKey: [String: String] = [:]
        for (key, acc) in byKey {
            if let p = acc.path, let root = appBundleRoot(from: p) {
                bundleRootToKey[root] = key
            }
            // 也用 runningApplications 的 bundleURL
        }
        for app in runningApps {
            guard let root = app.bundleURL?.path else { continue }
            let bid = app.bundleIdentifier ?? ""
            let key = normalizeMatchKey(
                bundleID: bid,
                path: root,
                name: app.localizedName ?? root
            )
            bundleRootToKey[root] = key
            // 确保 key 存在
            if byKey[key] == nil {
                byKey[key] = Acc(
                    name: app.localizedName ?? URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent,
                    matchKey: key,
                    path: root,
                    isApp: true,
                    pids: [],
                    ips: [],
                    policy: app.activationPolicy
                )
            }
        }

        for (pid, helperPath) in pathByPID {
            guard let root = appBundleRoot(from: helperPath) else { continue }
            let key: String
            if let existing = bundleRootToKey[root] {
                key = existing
            } else {
                // 未知包：用 Bundle ID 或包路径作为 key
                let bid = bundleIdentifier(atAppRoot: root) ?? ""
                key = normalizeMatchKey(
                    bundleID: bid,
                    path: root,
                    name: URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
                )
                bundleRootToKey[root] = key
                if byKey[key] == nil {
                    byKey[key] = Acc(
                        name: URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent,
                        matchKey: key,
                        path: root,
                        isApp: true,
                        pids: [],
                        ips: [],
                        policy: .regular
                    )
                }
            }
            var acc = byKey[key]!
            acc.pids.insert(pid)
            if let ips = ipsByPID[pid] {
                acc.ips.formUnion(ips)
            }
            if acc.path == nil { acc.path = root }
            byKey[key] = acc
            claimedPIDs.insert(pid)
        }

        // 剩余无包归属的进程（命令行等）
        for (pid, ips) in ipsByPID where !claimedPIDs.contains(pid) {
            if !includeSystem && pid < 50 { continue }
            let path = pathByPID[pid]
            // 再尝试一次 .app 归属（path 可能刚解析到）
            if let path, let root = appBundleRoot(from: path) {
                let bid = bundleIdentifier(atAppRoot: root) ?? ""
                let key = normalizeMatchKey(
                    bundleID: bid,
                    path: root,
                    name: URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
                )
                var acc = byKey[key] ?? Acc(
                    name: URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent,
                    matchKey: key,
                    path: root,
                    isApp: true,
                    pids: [],
                    ips: [],
                    policy: .regular
                )
                acc.pids.insert(pid)
                acc.ips.formUnion(ips)
                byKey[key] = acc
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
                policy: .prohibited
            )
            acc.pids.insert(pid)
            acc.ips.formUnion(ips)
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
                    remoteIPs: ipList
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

    /// 稳定 matchKey：Bundle ID > .app 路径 > 名称
    nonisolated static func normalizeMatchKey(bundleID: String, path: String?, name: String) -> String {
        if !bundleID.isEmpty { return bundleID }
        if let path, let root = appBundleRoot(from: path) {
            if let bid = bundleIdentifier(atAppRoot: root), !bid.isEmpty {
                return bid
            }
            return root
        }
        if let path, !path.isEmpty { return path }
        return name
    }

    nonisolated static func isBundleID(_ s: String) -> Bool {
        // com.google.Chrome 等
        s.contains(".") && !s.contains("/") && !s.hasSuffix(".app")
    }

    /// 从任意可执行路径提取最外层 .app 根路径
    nonisolated static func appBundleRoot(from path: String) -> String? {
        // /Applications/Google Chrome.app/Contents/Frameworks/... → .../Google Chrome.app
        var url = URL(fileURLWithPath: path)
        var found: String?
        while url.path != "/" {
            if url.pathExtension == "app" {
                found = url.path
                // 继续向上，取最外层（应对 Foo.app/Contents/Frameworks/Bar.app 少见情况时取外层）
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

    /// 「Google Chrome」与「Google Chrome Helper (Renderer)」视为同一应用
    nonisolated static func namesBelongToSameApp(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty || y.isEmpty { return false }
        if x.caseInsensitiveCompare(y) == .orderedSame { return true }

        let xl = x.lowercased()
        let yl = y.lowercased()

        // 去掉 Helper / Renderer 等后缀再比
        func stem(_ s: String) -> String {
            var t = s
            let suffixes = [
                " helper (renderer)", " helper (gpu)", " helper (plugin)",
                " helper", " renderer", " (renderer)", " (gpu)", " (plugin)"
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
        if xs == ys { return true }
        if xs.hasPrefix(ys) || ys.hasPrefix(xs) {
            // 避免 "Mail" 误匹配 "Mail Service" 过短：要求较短方至少 4 字符
            let shorter = min(xs.count, ys.count)
            return shorter >= 4
        }
        return false
    }

    // MARK: - Connections

    private struct Conn {
        let pid: Int32
        let command: String
        let remoteIP: String
    }

    nonisolated private static func loadConnections() -> [Conn] {
        let cmd = "/usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null"
        guard let out = try? Shell.run(cmd, timeout: 30, requireZeroExit: false),
              !out.isEmpty
        else {
            return []
        }

        var list: [Conn] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("COMMAND") || line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 9 else { continue }
            let command = parts[0]
            guard let pid = Int32(parts[1]) else { continue }

            let name: String
            if let idx = parts.firstIndex(of: "TCP") ?? parts.firstIndex(of: "UDP") {
                name = parts[(idx + 1)...].joined(separator: " ")
            } else {
                name = parts[8...].joined(separator: " ")
            }

            guard let remote = extractRemoteIP(from: name) else { continue }
            list.append(Conn(pid: pid, command: command, remoteIP: remote))
        }
        return list
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

    nonisolated private static func isPublicOrRoutable(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 127 { return false }
        if parts[0] == 0 { return false }
        if parts[0] == 255 { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }
        if (224...239).contains(parts[0]) { return false }
        return true
    }

    nonisolated private static func processPath(pid: Int32) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(PATH_MAX))
        defer { buf.deallocate() }
        let ret = proc_pidpath(pid, buf, UInt32(PATH_MAX))
        guard ret > 0 else { return nil }
        return String(cString: buf)
    }
}

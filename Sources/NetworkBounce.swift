import Foundation
import AppKit

/// 主机路由写入后，旧 TCP/QUIC 连接仍绑在 VPN 地址上不会自动切换。
/// 对 Chrome 等：温和结束 Network Service helper，迫使按新路由重连。
enum NetworkBounce {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastBounceAt: [String: Date] = [:]

    /// - Returns: 实际尝试重启网络进程的应用名列表
    @discardableResult
    nonisolated static func bounceAppsIfNeeded(
        processes: [ProcessItem],
        localModeMatchKeys: Set<String>,
        vpnInterfaceAddresses: Set<String> = []
    ) -> [String] {
        var bounced: [String] = []
        let now = Date()

        for proc in processes {
            guard localModeMatchKeys.contains(proc.matchKey) else { continue }
            // 仍有连接走 VPN 源地址 → 需要重置
            guard !proc.vpnBoundRemoteIPs.isEmpty else { continue }
            // 若调用方提供了 VPN 地址集合，可再校验；无则信任连接扫描结果
            _ = vpnInterfaceAddresses

            lock.lock()
            let last = lastBounceAt[proc.matchKey]
            let tooSoon = last.map { now.timeIntervalSince($0) < 12 } ?? false
            lock.unlock()
            if tooSoon { continue }

            let killed = killNetworkHelpers(for: proc)
            if killed > 0 {
                lock.lock()
                lastBounceAt[proc.matchKey] = now
                lock.unlock()
                bounced.append(proc.name)
            }
        }
        return bounced
    }

    /// 用户刚点了「走本地」时强制重置一次（不受 vpnBound 列表限制）
    @discardableResult
    nonisolated static func forceBounce(process: ProcessItem) -> Bool {
        lock.lock()
        lastBounceAt[process.matchKey] = Date()
        lock.unlock()
        return killNetworkHelpers(for: process) > 0
    }

    nonisolated private static func killNetworkHelpers(for process: ProcessItem) -> Int {
        var pids = Set(process.networkPIDs)

        // 按路径再扫一遍 Network Service / 带网络的 helper
        if let root = process.path.flatMap({ ProcessMonitor.appBundleRoot(from: $0) })
            ?? process.path
        {
            pids.formUnion(findHelperPIDs(underAppRoot: root))
        }

        // Chrome / Edge / Brave / Arc 等 Chromium：优先 network.mojom.NetworkService
        let name = process.name.lowercased()
        let bid = process.matchKey.lowercased()
        if name.contains("chrome") || bid.contains("chrome")
            || name.contains("edge") || bid.contains("edge")
            || name.contains("brave") || bid.contains("brave")
            || name.contains("arc") || bid.contains("browser")
        {
            pids.formUnion(findChromiumNetworkServicePIDs(appHint: process.name))
        }

        var killed = 0
        for pid in pids where pid > 1 {
            // 只杀 helper，尽量不动主进程窗口
            if isMainBrowserProcess(pid: pid, process: process) { continue }
            if kill(pid, SIGTERM) == 0 {
                killed += 1
            }
        }
        return killed
    }

    nonisolated private static func isMainBrowserProcess(pid: Int32, process: ProcessItem) -> Bool {
        // 主进程通常是 .app/Contents/MacOS/AppName，而不是 Helpers/
        guard let path = ProcessMonitor.processPathPublic(pid: pid) else { return false }
        if path.contains("/Helpers/") { return false }
        if path.contains("Helper") { return false }
        // 若 pid 就是我们展示的代表 pid 且路径在 MacOS 下，视为主进程
        if pid == process.pid, path.contains("/Contents/MacOS/") {
            return true
        }
        return false
    }

    nonisolated private static func findHelperPIDs(underAppRoot root: String) -> Set<Int32> {
        var result = Set<Int32>()
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            guard let path = ProcessMonitor.processPathPublic(pid: pid) else { continue }
            guard path.hasPrefix(root) else { continue }
            // Network / GPU 以外：带 network 的 utility，或所有 Helper（偏保守只杀 network）
            let lower = path.lowercased()
            if lower.contains("helper") {
                // 通过 args 再过滤
                if let args = processArguments(pid: pid)?.lowercased() {
                    if args.contains("network.mojom.networkservice")
                        || args.contains("utility-sub-type=network")
                        || (args.contains("--type=utility") && args.contains("network"))
                    {
                        result.insert(pid)
                    }
                }
            }
        }
        // 也扫所有进程路径在包内且 args 含 network service
        result.formUnion(scanAllPIDsForNetworkService(appRoot: root))
        return result
    }

    nonisolated private static func findChromiumNetworkServicePIDs(appHint: String) -> Set<Int32> {
        scanAllPIDsForNetworkService(appRoot: nil, nameContains: "chrome")
            .union(scanAllPIDsForNetworkService(appRoot: nil, nameContains: "chromium"))
    }

    nonisolated private static func scanAllPIDsForNetworkService(
        appRoot: String?,
        nameContains: String? = nil
    ) -> Set<Int32> {
        var result = Set<Int32>()
        // 用 ps 扫描，避免遗漏
        guard let out = try? Shell.run(
            "/bin/ps -axo pid=,command= 2>/dev/null",
            timeout: 8,
            requireZeroExit: false
        ) else { return result }

        for line in out.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            let cmd = String(trimmed[trimmed.index(after: space)...])
            let lower = cmd.lowercased()
            guard lower.contains("network.mojom.networkservice")
                || lower.contains("utility-sub-type=network")
            else { continue }
            if let appRoot, !cmd.hasPrefix(appRoot) && !cmd.contains(appRoot) {
                // ps 路径可能是绝对路径
                if !cmd.contains(appRoot) { continue }
            }
            if let nameContains, !lower.contains(nameContains) {
                // 若指定了 chrome 提示，路径里通常有 Google Chrome
                if !lower.contains("google chrome") && !lower.contains(nameContains) {
                    continue
                }
            }
            result.insert(pid)
        }
        return result
    }

    nonisolated private static func processArguments(pid: Int32) -> String? {
        // ps -p PID -o args=
        try? Shell.run("/bin/ps -p \(pid) -o args= 2>/dev/null", timeout: 3, requireZeroExit: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// 暴露给 NetworkBounce 的路径解析
extension ProcessMonitor {
    nonisolated static func processPathPublic(pid: Int32) -> String? {
        processPathForPID(pid)
    }
}

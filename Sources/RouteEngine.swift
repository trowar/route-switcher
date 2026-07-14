import Foundation

/// 根据规则把进程的远程目标主机路由到 VPN 或本地网关
actor RouteEngine {
    private(set) var applied: [AppliedRoute] = []

    func currentApplied() -> [AppliedRoute] { applied }

    func sync(
        targets: [RouteMode: [(ip: String, processName: String)]],
        network: NetworkSnapshot
    ) async throws {
        var desired: [String: AppliedRoute] = [:]

        // 保护：不要给网关自身、本机局域网关键地址写主机路由
        let protectedIPs = protectedDestinations(network: network)

        for (ip, processName) in targets[.vpn] ?? [] {
            guard network.vpnAvailable else { continue }
            guard !protectedIPs.contains(ip) else { continue }
            let via: String
            if let gw = network.vpnGateway {
                via = "gw:\(gw)"
            } else if let iface = network.vpnInterface {
                via = "if:\(iface)"
            } else {
                continue
            }
            desired[ip] = AppliedRoute(
                destination: ip,
                mode: .vpn,
                processName: processName,
                via: via
            )
        }

        for (ip, processName) in targets[.local] ?? [] {
            guard network.localAvailable else { continue }
            guard !protectedIPs.contains(ip) else { continue }
            let via: String
            if let gw = network.localGateway {
                via = "gw:\(gw)"
            } else if let iface = network.localInterface {
                via = "if:\(iface)"
            } else {
                continue
            }
            if desired[ip] == nil {
                desired[ip] = AppliedRoute(
                    destination: ip,
                    mode: .local,
                    processName: processName,
                    via: via
                )
            }
        }

        let currentByIP = Dictionary(uniqueKeysWithValues: applied.map { ($0.destination, $0) })
        let desiredKeys = Set(desired.keys)
        let currentKeys = Set(currentByIP.keys)

        let toRemove = currentKeys.subtracting(desiredKeys)
        let toAdd = desiredKeys.subtracting(currentKeys)
        let toUpdate = desiredKeys.intersection(currentKeys).filter { ip in
            guard let old = currentByIP[ip], let neu = desired[ip] else { return false }
            return old.mode != neu.mode || old.via != neu.via
        }

        var commands: [String] = []
        for ip in toRemove.union(toUpdate) {
            commands.append("/sbin/route -n delete -host \(ip) 2>/dev/null || true")
        }
        for ip in toAdd.union(toUpdate) {
            guard let route = desired[ip] else { continue }
            if let line = addCommand(for: route, network: network) {
                commands.append("/sbin/route -n delete -host \(ip) 2>/dev/null || true")
                commands.append(line)
            }
        }

        if !commands.isEmpty {
            try await PrivilegeSession.shared.runRouteScript(commands.joined(separator: "\n"))
        }

        applied = desired.values.sorted { $0.destination < $1.destination }
    }

    func clearAll() async throws {
        if applied.isEmpty { return }
        var lines: [String] = []
        for route in applied {
            lines.append("/sbin/route -n delete -host \(route.destination) 2>/dev/null || true")
        }
        try await PrivilegeSession.shared.runRouteScript(lines.joined(separator: "\n"))
        applied.removeAll()
    }

    /// 仅清除走 VPN 的主机路由（VPN 断开时调用）
    func clearVPNRoutes() async throws {
        let vpnOnes = applied.filter { $0.mode == .vpn }
        guard !vpnOnes.isEmpty else { return }
        var lines: [String] = []
        for route in vpnOnes {
            lines.append("/sbin/route -n delete -host \(route.destination) 2>/dev/null || true")
        }
        try await PrivilegeSession.shared.runRouteScript(lines.joined(separator: "\n"))
        applied.removeAll { $0.mode == .vpn }
    }

    /// 若系统缺少可用 IPv4 默认路由，用本机网关恢复（修复 OpenVPN 断开后网关丢失）
    /// - Returns: 是否执行了恢复命令
    @discardableResult
    func restoreDefaultRouteIfNeeded(network: NetworkSnapshot) async throws -> Bool {
        guard network.defaultRouteMissing else { return false }
        guard let gw = network.localGateway, isIPv4(gw) else { return false }

        var lines: [String] = []
        // 1) 删掉指向失效 VPN 对端的 default（避免误删 Parallels bridge 的 link default）
        if let stale = network.lastKnownVPNGateway, isIPv4(stale), stale != gw {
            lines.append("/sbin/route -n delete default \(stale) 2>/dev/null || true")
        }
        // 2) 若同网关已存在则先删再加，保证生效
        lines.append("/sbin/route -n delete default \(gw) 2>/dev/null || true")
        lines.append("/sbin/route -n add default \(gw)")
        try await PrivilegeSession.shared.runRouteScript(lines.joined(separator: "\n"))
        return true
    }

    private func protectedDestinations(network: NetworkSnapshot) -> Set<String> {
        var s = Set<String>()
        if let g = network.localGateway { s.insert(g) }
        if let g = network.vpnGateway { s.insert(g) }
        if let g = network.defaultGateway { s.insert(g) }
        return s
    }

    private func addCommand(for route: AppliedRoute, network: NetworkSnapshot) -> String? {
        let ip = route.destination
        switch route.mode {
        case .vpn:
            if let gw = network.vpnGateway {
                return "/sbin/route -n add -host \(ip) \(gw)"
            }
            if let iface = network.vpnInterface {
                return "/sbin/route -n add -host \(ip) -interface \(iface)"
            }
            return nil
        case .local:
            if let gw = network.localGateway {
                return "/sbin/route -n add -host \(ip) \(gw)"
            }
            if let iface = network.localInterface {
                return "/sbin/route -n add -host \(ip) -interface \(iface)"
            }
            return nil
        case .system:
            return nil
        }
    }

    private func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let n = Int(p), (0...255).contains(n) else { return false }
            return true
        }
    }
}

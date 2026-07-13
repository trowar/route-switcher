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

        for (ip, processName) in targets[.vpn] ?? [] {
            guard network.vpnAvailable else { continue }
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
}

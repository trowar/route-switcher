import Foundation

/// 发现 VPN / 本地物理接口与网关
enum NetworkInterfaceManager {
    nonisolated static func snapshot() -> NetworkSnapshot {
        let interfaces = listInterfaces()
        let table = routingTable()
        let ifaceAddrs = interfaceAddresses()

        let defaultCandidates = table.filter { $0.destination == "default" }
        let physicalDefault = defaultCandidates.first { $0.interface.hasPrefix("en") }
        let anyDefault = physicalDefault ?? defaultCandidates.first

        let defaultInterface = anyDefault?.interface
        let defaultGateway = anyDefault.flatMap { isIP($0.gateway) ? $0.gateway : nil }

        var localInterface = physicalDefault?.interface
        var localGateway = physicalDefault.flatMap { isIP($0.gateway) ? $0.gateway : nil }

        if localInterface == nil {
            localInterface = interfaces.first { $0.hasPrefix("en") && ifaceAddrs[$0] != nil }
        }
        if localGateway == nil, let en = localInterface {
            localGateway = gatewayForInterface(en) ?? detectLocalGatewayViaNetworksetup()
        }
        if localGateway == nil {
            localGateway = defaultGateway
        }

        var vpnInterface: String?
        var vpnGateway: String?

        // 1) 带 IPv4 的 utun/ipsec/ppp（如 OpenVPN utun4: 10.8.0.10 --> 10.8.0.1）
        let vpnIfNames = interfaces.filter {
            $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") || $0.hasPrefix("wg")
        }
        for name in vpnIfNames {
            if let ip = ifaceAddrs[name], isIP(ip) {
                vpnInterface = name
                vpnGateway = ifacePeers[name] ?? peerGateway(from: ip) ?? gatewayOnInterface(name, table: table)
                break
            }
        }

        // 2) 路由表：0/1、128.0/1 走 utun 是典型 OpenVPN 全隧道
        for route in table {
            let dest = route.destination
            let iface = route.interface
            if iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp") {
                if vpnInterface == nil {
                    vpnInterface = iface
                }
                if vpnGateway == nil, isIP(route.gateway) {
                    vpnGateway = route.gateway
                }
                if dest == "0/1" || dest == "128.0/1" || dest.hasPrefix("0/") {
                    vpnInterface = iface
                    if isIP(route.gateway) { vpnGateway = route.gateway }
                }
            }
        }

        // 3) 点对端网关投票（主机路由）
        if vpnGateway == nil {
            var votes: [String: Int] = [:]
            for route in table {
                guard isIP(route.gateway) else { continue }
                if route.gateway == localGateway { continue }
                if route.destination == "default" { continue }
                votes[route.gateway, default: 0] += 1
            }
            if let best = votes.max(by: { $0.value < $1.value }), best.value >= 1 {
                vpnGateway = best.key
            }
        }

        if vpnInterface == nil, let last = vpnIfNames.filter({ ifaceAddrs[$0] != nil }).last {
            vpnInterface = last
        }

        let isVPNDefault: Bool = {
            guard let iface = defaultInterface else { return false }
            return iface.hasPrefix("utun") || iface.hasPrefix("ipsec")
                || iface.hasPrefix("ppp") || iface.hasPrefix("wg")
        }() || table.contains {
            ($0.destination == "0/1" || $0.destination == "128.0/1")
                && ($0.interface.hasPrefix("utun") || $0.interface.hasPrefix("ppp"))
        }

        let vpnAvailable = vpnGateway != nil || vpnInterface != nil
            || ifaceAddrs.keys.contains(where: { $0.hasPrefix("utun") && ifaceAddrs[$0] != nil })

        return NetworkSnapshot(
            vpnInterface: vpnInterface,
            vpnGateway: vpnGateway,
            localInterface: localInterface,
            localGateway: localGateway,
            defaultInterface: defaultInterface,
            defaultGateway: defaultGateway,
            isVPNDefault: isVPNDefault,
            interfaces: interfaces,
            vpnAvailableOverride: vpnAvailable
        )
    }

    // 解析 ifconfig 时填充：接口 → 对端地址
    private static let ifacePeersLock = NSLock()
    nonisolated(unsafe) private static var ifacePeers: [String: String] = [:]

    private struct RouteEntry {
        let destination: String
        let gateway: String
        let interface: String
    }

    nonisolated private static func listInterfaces() -> [String] {
        (try? Shell.run("/sbin/ifconfig -l"))?
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
    }

    nonisolated private static func interfaceAddresses() -> [String: String] {
        guard let out = try? Shell.run("/sbin/ifconfig") else { return [:] }
        var result: [String: String] = [:]
        var peers: [String: String] = [:]
        var current: String?

        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                current = line.split(separator: ":").first.map(String.init)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet "), let iface = current else { continue }
            // inet 10.8.0.10 --> 10.8.0.1 netmask 0xffffff00
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 2, isIP(parts[1]) else { continue }
            let ip = parts[1]
            if ip != "127.0.0.1" {
                result[iface] = ip
            }
            if let arrow = parts.firstIndex(of: "-->"), arrow + 1 < parts.count {
                let peer = parts[arrow + 1]
                if isIP(peer) {
                    peers[iface] = peer
                }
            }
        }
        ifacePeersLock.lock()
        ifacePeers = peers
        ifacePeersLock.unlock()
        return result
    }

    nonisolated private static func routingTable() -> [RouteEntry] {
        guard let out = try? Shell.run("/usr/sbin/netstat -rn -f inet") else { return [] }
        var result: [RouteEntry] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 4 else { continue }
            let dest = parts[0]
            if dest == "Destination" || dest == "Routing" || dest.hasPrefix("Internet") {
                continue
            }
            let gateway = parts[1]
            // 列数不固定：有时无 Refs/Use
            // 常见 4 列: dest gw flags netif
            // 常见 6 列: dest gw flags refs use netif
            let iface: String
            if parts.count >= 6, !parts[5].allSatisfy(\.isNumber) {
                iface = parts[5]
            } else {
                iface = parts.last ?? ""
            }
            if iface.isEmpty || iface.allSatisfy(\.isNumber) { continue }
            result.append(RouteEntry(destination: dest, gateway: gateway, interface: iface))
        }
        return result
    }

    nonisolated private static func gatewayForInterface(_ iface: String) -> String? {
        guard let out = try? Shell.run("/sbin/route -n get -ifscope \(iface) default 2>/dev/null || true") else {
            return nil
        }
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("gateway:") {
                let gw = s.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if isIP(gw) { return gw }
            }
        }
        return nil
    }

    nonisolated private static func gatewayOnInterface(_ iface: String, table: [RouteEntry]) -> String? {
        for route in table where route.interface == iface {
            if isIP(route.gateway) { return route.gateway }
        }
        return nil
    }

    nonisolated private static func peerGateway(from localIP: String) -> String? {
        let parts = localIP.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    nonisolated private static func detectLocalGatewayViaNetworksetup() -> String? {
        guard let services = try? Shell.run("/usr/sbin/networksetup -listallnetworkservices") else {
            return nil
        }
        for raw in services.split(separator: "\n").map(String.init) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.hasPrefix("An asterisk") || name.hasPrefix("*") { continue }
            let lower = name.lowercased()
            if lower.contains("vpn") || lower.contains("utun") || lower.contains("tailscale") {
                continue
            }
            guard let info = try? Shell.run("/usr/sbin/networksetup -getinfo \(shellQuote(name))") else {
                continue
            }
            var router: String?
            var ip: String?
            for line in info.split(separator: "\n").map(String.init) {
                if line.hasPrefix("Router:") {
                    router = line.replacingOccurrences(of: "Router:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
                if line.hasPrefix("IP address:") {
                    ip = line.replacingOccurrences(of: "IP address:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            if let router, isIP(router), router != "none", ip != nil {
                return router
            }
        }
        return nil
    }

    nonisolated private static func isIP(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let n = Int(p), (0...255).contains(n) else { return false }
            return true
        }
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

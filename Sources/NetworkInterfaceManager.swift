import Foundation

/// 发现 VPN / 本地物理接口与网关
enum NetworkInterfaceManager {
    /// 记住最近一次可靠的本机物理网关，供 VPN 断开后恢复默认路由
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedLocalGateway: String?
    nonisolated(unsafe) private static var cachedLocalInterface: String?
    /// VPN 在线时记住隧道网关，断开后用于删掉残留 default
    nonisolated(unsafe) private static var cachedVPNGateway: String?

    nonisolated static func snapshot() -> NetworkSnapshot {
        let interfaces = listInterfaces()
        let table = routingTable()
        // 每次 snapshot 原子解析 ifconfig，避免与并发 snapshot 抢全局 peers
        let ifconfig = parseIfconfig()

        let defaultCandidates = table.filter { isDefaultDestination($0.destination) }
        // 真正的本机默认：物理 en* 且网关是 IPv4（排除 bridge 的 link# 默认）
        let physicalDefault = defaultCandidates.first {
            $0.interface.hasPrefix("en") && isIP($0.gateway)
        }
        let anyIPDefault = defaultCandidates.first { isIP($0.gateway) }
        let anyDefault = physicalDefault ?? anyIPDefault ?? defaultCandidates.first

        let defaultInterface = anyDefault?.interface
        let defaultGateway = anyDefault.flatMap { isIP($0.gateway) ? $0.gateway : nil }

        var localInterface = physicalDefault?.interface
        var localGateway = physicalDefault.flatMap { isIP($0.gateway) ? $0.gateway : nil }

        if localInterface == nil {
            localInterface = preferredPhysicalInterface(interfaces: interfaces, addrs: ifconfig.addrs)
        }
        if localGateway == nil, let en = localInterface {
            localGateway = gatewayForInterface(en) ?? detectLocalGatewayViaNetworksetup()
        }
        if localGateway == nil {
            localGateway = detectLocalGatewayViaNetworksetup()
        }
        // 不要把 VPN 默认网关当成 local（OpenVPN 全隧道时 default 可能在 utun）
        if let lg = localGateway, let di = defaultInterface, isVPNInterface(di), lg == defaultGateway {
            if let en = preferredPhysicalInterface(interfaces: interfaces, addrs: ifconfig.addrs) {
                localInterface = en
                localGateway = gatewayForInterface(en)
                    ?? detectLocalGatewayViaNetworksetup()
                    ?? readCachedLocal().gateway
            }
        }

        // 写入/读出缓存：有可靠物理网关时更新；丢失时回退缓存
        if let lg = localGateway, isIP(lg) {
            let iface = localInterface ?? preferredPhysicalInterface(interfaces: interfaces, addrs: ifconfig.addrs)
            writeCachedLocal(gateway: lg, interface: iface)
        } else if localGateway == nil {
            let cached = readCachedLocal()
            localGateway = cached.gateway
            if localInterface == nil {
                localInterface = cached.interface
            }
        }

        let vpn = detectVPN(
            interfaces: interfaces,
            table: table,
            addrs: ifconfig.addrs,
            peers: ifconfig.peers,
            localGateway: localGateway
        )

        if vpn.up, let vg = vpn.gateway, isIP(vg) {
            cacheLock.lock()
            cachedVPNGateway = vg
            cacheLock.unlock()
        }

        let lastVPNGateway: String? = {
            if let vg = vpn.gateway { return vg }
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return cachedVPNGateway
        }()

        let vpnInterface = vpn.up ? vpn.interface : nil
        let vpnGateway = vpn.up ? vpn.gateway : nil

        // 默认路由是否可用
        let hasPhysicalIPDefault = defaultCandidates.contains {
            isIP($0.gateway) && $0.interface.hasPrefix("en")
        }
        let hasVPNIPDefault = defaultCandidates.contains {
            isIP($0.gateway) && isVPNInterface($0.interface)
        }
        let hasStaleVPNDefault = !vpn.up && defaultCandidates.contains { entry in
            guard isIP(entry.gateway) else { return false }
            if let last = lastVPNGateway, entry.gateway == last { return true }
            return isVPNInterface(entry.interface)
        }
        let defaultRouteMissing: Bool = {
            if vpn.up {
                return !(hasPhysicalIPDefault || hasVPNIPDefault || vpn.splitDefault)
            }
            return !hasPhysicalIPDefault || hasStaleVPNDefault
        }()

        return NetworkSnapshot(
            vpnInterface: vpnInterface,
            vpnGateway: vpnGateway,
            localInterface: localInterface,
            localGateway: localGateway,
            defaultInterface: defaultInterface,
            defaultGateway: defaultGateway,
            isVPNDefault: vpn.up && (vpn.splitDefault || (defaultInterface.map(isVPNInterface) ?? false)),
            interfaces: interfaces,
            vpnAvailableOverride: vpn.up,
            defaultRouteMissing: defaultRouteMissing,
            lastKnownVPNGateway: lastVPNGateway
        )
    }

    // MARK: - VPN detection

    private struct VPNDetect {
        var interface: String?
        var gateway: String?
        var splitDefault: Bool
        var up: Bool
    }

    /// OpenVPN Connect 典型特征：
    /// - 新建 utunN：`ifconfig utun6 10.8.0.10 10.8.0.1 netmask …`
    /// - `0/1` + `128.0/1` 经 VPN 网关（redirect-gateway def1）
    nonisolated private static func detectVPN(
        interfaces: [String],
        table: [RouteEntry],
        addrs: [String: String],
        peers: [String: String],
        localGateway: String?
    ) -> VPNDetect {
        var vpnInterface: String?
        var vpnGateway: String?
        var splitDefault = false

        // 候选隧道：按编号从大到小（OpenVPN Connect 常新建最大号 utun）
        let tunnelIfs = interfaces
            .filter { isVPNInterface($0) }
            .sorted { utunIndex($0) > utunIndex($1) }

        // 1) 带 IPv4 的隧道接口（排除 Parallels 共享网段误伤）
        for name in tunnelIfs {
            guard let ip = addrs[name], isIP(ip), !isParallelsSharedIP(ip) else { continue }
            vpnInterface = name
            vpnGateway = peers[name]
                ?? peerGateway(from: ip)
                ?? gatewayOnInterface(name, table: table, preferNot: ip)
            break
        }

        // 2) 路由表信号（即使 ifconfig 解析失败也能识别）
        for route in table {
            let dest = route.destination
            let iface = route.interface
            let isTunnel = isVPNInterface(iface)

            if isOpenVPNSplitDefault(dest) {
                // 0/1、128.0/1 — 即使 netif 列异常，网关也常是 10.8.0.1
                splitDefault = true
                if isTunnel {
                    vpnInterface = iface
                }
                if isIP(route.gateway) {
                    // 不要把本机局域网路由器当成 VPN 网关
                    if route.gateway != localGateway {
                        vpnGateway = route.gateway
                    }
                }
                continue
            }

            guard isTunnel else { continue }

            if isDefaultDestination(dest), isIP(route.gateway), route.gateway != localGateway {
                vpnInterface = iface
                vpnGateway = route.gateway
            } else if isIP(route.gateway), route.gateway != localGateway {
                // 隧道上的其它路由：补全 interface / gateway
                if vpnInterface == nil { vpnInterface = iface }
                if vpnGateway == nil { vpnGateway = route.gateway }
            } else if vpnInterface == nil {
                vpnInterface = iface
            }
        }

        // 3) 隧道网段主机路由：10.8.0/24 via 10.8.0.10 等
        if vpnGateway == nil || vpnInterface == nil {
            for route in table where isVPNInterface(route.interface) {
                if let iface = vpnInterface ?? Optional(route.interface) {
                    if vpnInterface == nil { vpnInterface = iface }
                }
                // destination 像 10.8.0/24 且 gateway 是接口地址时，peer 常为 .1
                if vpnGateway == nil, let ip = addrs[route.interface] {
                    vpnGateway = peers[route.interface] ?? peerGateway(from: ip)
                }
            }
        }

        // 4) 仅有接口无网关时，用 peer / .1 启发式
        if vpnGateway == nil, let iface = vpnInterface {
            vpnGateway = peers[iface]
                ?? addrs[iface].flatMap { peerGateway(from: $0) }
                ?? gatewayOnInterface(iface, table: table, preferNot: addrs[iface])
        }

        let hasLiveAddr = tunnelIfs.contains { name in
            guard let ip = addrs[name], isIP(ip) else { return false }
            return !isParallelsSharedIP(ip)
        }

        // 在线判定：分流路由 / 有效隧道地址 / 接口+网关齐备
        let up = splitDefault
            || hasLiveAddr
            || (vpnInterface != nil && vpnGateway != nil && isIP(vpnGateway!))

        // 有 split default 但没解析出 interface 时，仍标为可用（走 gw 加路由）
        if up, vpnInterface == nil, let gw = vpnGateway {
            // 反查：哪张网卡路由指向该网关
            for route in table where route.gateway == gw && isVPNInterface(route.interface) {
                vpnInterface = route.interface
                break
            }
        }

        return VPNDetect(
            interface: up ? vpnInterface : nil,
            gateway: up ? vpnGateway : nil,
            splitDefault: splitDefault,
            up: up
        )
    }

    nonisolated private static func isOpenVPNSplitDefault(_ dest: String) -> Bool {
        // netstat 常见：0/1、128.0/1；偶发 0.0.0.0/1、128.0.0.0/1
        let d = dest.lowercased()
        return d == "0/1" || d == "128.0/1"
            || d == "0.0.0.0/1" || d == "128.0.0.0/1"
            || d == "0.0.0.0/1.0.0.0" // 极少见
    }

    nonisolated private static func isDefaultDestination(_ dest: String) -> Bool {
        dest == "default" || dest == "0.0.0.0" || dest == "0.0.0.0/0"
    }

    nonisolated private static func utunIndex(_ name: String) -> Int {
        if name.hasPrefix("utun"), let n = Int(name.dropFirst(4)) { return n }
        if name.hasPrefix("ipsec"), let n = Int(name.dropFirst(5)) { return n }
        if name.hasPrefix("ppp"), let n = Int(name.dropFirst(3)) { return n }
        if name.hasPrefix("wg"), let n = Int(name.dropFirst(2)) { return n }
        return -1
    }

    // MARK: - Cache

    nonisolated private static func writeCachedLocal(gateway: String, interface: String?) {
        cacheLock.lock()
        cachedLocalGateway = gateway
        if let interface { cachedLocalInterface = interface }
        cacheLock.unlock()
    }

    nonisolated private static func readCachedLocal() -> (gateway: String?, interface: String?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (cachedLocalGateway, cachedLocalInterface)
    }

    // MARK: - Helpers

    private struct RouteEntry {
        let destination: String
        let gateway: String
        let interface: String
    }

    private struct IfconfigParse {
        var addrs: [String: String]
        var peers: [String: String]
    }

    nonisolated private static func isVPNInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec")
            || name.hasPrefix("ppp") || name.hasPrefix("wg")
    }

    nonisolated private static func isNetifToken(_ tok: String) -> Bool {
        if tok.isEmpty || tok.allSatisfy(\.isNumber) { return false }
        // flags 如 UGScg、UHLWIir 全是字母
        if tok.allSatisfy(\.isLetter) { return false }
        let prefixes = [
            "utun", "en", "ipsec", "ppp", "wg", "bridge", "lo",
            "awdl", "llw", "ap", "gif", "stf", "vmenet", "anpi", "XHC"
        ]
        return prefixes.contains { tok.hasPrefix($0) }
    }

    /// Parallels 等共享网络有时挂在奇怪接口上，避免当 VPN
    nonisolated private static func isParallelsSharedIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10, parts[1] == 211, parts[2] == 55 { return true }
        if parts[0] == 10, parts[1] == 37, parts[2] == 129 { return true }
        return false
    }

    nonisolated private static func preferredPhysicalInterface(
        interfaces: [String],
        addrs: [String: String]
    ) -> String? {
        let ens = interfaces.filter { $0.hasPrefix("en") && addrs[$0] != nil }
        if ens.contains("en0") { return "en0" }
        return ens.first
    }

    nonisolated private static func listInterfaces() -> [String] {
        (try? Shell.run("/sbin/ifconfig -l"))?
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
    }

    nonisolated private static func parseIfconfig() -> IfconfigParse {
        guard let out = try? Shell.run("/sbin/ifconfig") else {
            return IfconfigParse(addrs: [:], peers: [:])
        }
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
            // 形式 A: inet 10.8.0.10 --> 10.8.0.1 netmask 0xffffff00
            // 形式 B: inet 10.8.0.10 netmask 0xffffff00
            // 形式 C: inet 10.8.0.10 netmask 0xffffff00 destination 10.8.0.1
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 2, isIP(parts[1]) else { continue }
            let ip = parts[1]
            if ip != "127.0.0.1" {
                result[iface] = ip
            }
            if let arrow = parts.firstIndex(of: "-->"), arrow + 1 < parts.count {
                let peer = parts[arrow + 1]
                if isIP(peer) { peers[iface] = peer }
            } else if let destIdx = parts.firstIndex(of: "destination"), destIdx + 1 < parts.count {
                let peer = parts[destIdx + 1]
                if isIP(peer) { peers[iface] = peer }
            } else if parts.count >= 3, isIP(parts[2]), !parts[2].hasPrefix("0x") {
                // 少数输出: inet LOCAL DEST netmask …
                // 但 netmask 也可能在 parts[2]——仅当是 IP 且不是 netmask 关键字
                let maybe = parts[2]
                if maybe != "netmask", isIP(maybe) {
                    peers[iface] = maybe
                }
            }
        }
        return IfconfigParse(addrs: result, peers: peers)
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
            // 接口名从右侧找：utun/en/ipsec/ppp/wg/bridge/lo/awdl…
            let iface: String = {
                if let found = parts.reversed().first(where: { isNetifToken($0) }) {
                    return found
                }
                if parts.count >= 6, !parts[5].allSatisfy(\.isNumber) {
                    return parts[5]
                }
                return parts.last ?? ""
            }()
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

    nonisolated private static func gatewayOnInterface(
        _ iface: String,
        table: [RouteEntry],
        preferNot: String? = nil
    ) -> String? {
        for route in table where route.interface == iface {
            guard isIP(route.gateway) else { continue }
            if let preferNot, route.gateway == preferNot { continue }
            return route.gateway
        }
        for route in table where route.interface == iface {
            if isIP(route.gateway) { return route.gateway }
        }
        return nil
    }

    nonisolated private static func peerGateway(from localIP: String) -> String? {
        let parts = localIP.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        // 点对点常见 .1；若本机就是 .1 则试 .2
        if parts[3] == 1 {
            return "\(parts[0]).\(parts[1]).\(parts[2]).2"
        }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    nonisolated private static func detectLocalGatewayViaNetworksetup() -> String? {
        guard let services = try? Shell.run("/usr/sbin/networksetup -listallnetworkservices") else {
            return nil
        }
        var candidates: [(name: String, router: String)] = []
        for raw in services.split(separator: "\n").map(String.init) {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.hasPrefix("An asterisk") || name.hasPrefix("*") { continue }
            let lower = name.lowercased()
            if lower.contains("vpn") || lower.contains("utun") || lower.contains("tailscale")
                || lower.contains("parallels") || lower.contains("bridge")
            {
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
                candidates.append((name, router))
            }
        }
        for prefer in ["wi-fi", "wifi", "ethernet", "usb", "thunderbolt"] {
            if let hit = candidates.first(where: { $0.name.lowercased().contains(prefer) }) {
                return hit.router
            }
        }
        return candidates.first?.router
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

import Foundation
import AppKit

/// 进程路由模式
enum RouteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case vpn = "vpn"
    case local = "local"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "默认"
        case .vpn: return "VPN"
        case .local: return "本地"
        }
    }

    /// 全局默认选项文案
    var defaultPolicyTitle: String {
        switch self {
        case .system: return "默认"
        case .vpn: return "VPN"
        case .local: return "本地"
        }
    }

    var shortTitle: String {
        switch self {
        case .system: return "默认"
        case .vpn: return "VPN"
        case .local: return "本地"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.dashed"
        case .vpn: return "lock.shield.fill"
        case .local: return "house.fill"
        }
    }

    var tint: String {
        switch self {
        case .system: return "secondary"
        case .vpn: return "blue"
        case .local: return "green"
        }
    }

    /// 行内三档开关顺序：左 VPN · 中 默认 · 右 本地
    static var switchOrder: [RouteMode] { [.vpn, .system, .local] }

    /// 三档开关上的短文案
    var switchLabel: String {
        switch self {
        case .vpn: return "VPN"
        case .system: return "默认"
        case .local: return "本地"
        }
    }
}

/// 用户配置的路由规则（按可执行名 / Bundle ID 匹配）
struct RouteRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// 进程名，例如 "Google Chrome"
    var processName: String
    /// Bundle ID（应用）或可执行路径
    var matchKey: String
    var mode: RouteMode
    var enabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        processName: String,
        matchKey: String,
        mode: RouteMode,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.processName = processName
        self.matchKey = matchKey
        self.mode = mode
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

/// 运行中的进程/应用项（同一 App 多窗口/Helper 合并为一行）
struct ProcessItem: Identifiable, Hashable, Sendable {
    /// 稳定 ID：按应用身份（Bundle ID），不随窗口/Helper 变化
    var id: String { matchKey }
    /// 代表 PID（主进程，仅展示用）
    let pid: Int32
    let name: String
    /// Bundle ID（优先）或 .app 路径，用于规则匹配
    let matchKey: String
    let path: String?
    let isApp: Bool
    let connectionCount: Int
    let remoteIPs: [String]
    /// 仍绑定在 VPN 接口地址上的远端 IP（主机路由已写但旧连接未切换）
    let vpnBoundRemoteIPs: [String]
    /// 该 App 下用于发起网络的 helper PID（含 Network Service）
    let networkPIDs: [Int32]

    func hash(into hasher: inout Hasher) {
        hasher.combine(matchKey)
    }

    static func == (lhs: ProcessItem, rhs: ProcessItem) -> Bool {
        lhs.matchKey == rhs.matchKey
    }
}

/// 网络接口信息
struct NetworkSnapshot: Sendable, Equatable {
    var vpnInterface: String?
    var vpnGateway: String?
    var localInterface: String?
    var localGateway: String?
    var defaultInterface: String?
    var defaultGateway: String?
    var isVPNDefault: Bool
    var interfaces: [String]
    /// 显式覆盖：有网关无接口时仍可用
    var vpnAvailableOverride: Bool?
    /// 系统缺少可用的 IPv4 默认路由（常见于 OpenVPN 断开后未恢复）
    var defaultRouteMissing: Bool
    /// 最近一次 VPN 隧道网关（断开后仍可用于清理残留 default）
    var lastKnownVPNGateway: String?

    var vpnAvailable: Bool {
        if let o = vpnAvailableOverride { return o }
        return vpnGateway != nil || vpnInterface != nil
    }

    var localAvailable: Bool { localGateway != nil || localInterface != nil }

    var vpnSummary: String {
        if let gw = vpnGateway, let iface = vpnInterface {
            return "\(iface) / \(gw)"
        }
        if let gw = vpnGateway { return "网关 \(gw)" }
        if let iface = vpnInterface { return iface }
        return "未检测到"
    }

    var localSummary: String {
        if let gw = localGateway, let iface = localInterface {
            return "\(iface) / \(gw)"
        }
        return localGateway ?? localInterface ?? "未检测到"
    }

    static let empty = NetworkSnapshot(
        vpnInterface: nil,
        vpnGateway: nil,
        localInterface: nil,
        localGateway: nil,
        defaultInterface: nil,
        defaultGateway: nil,
        isVPNDefault: false,
        interfaces: [],
        vpnAvailableOverride: nil,
        defaultRouteMissing: false,
        lastKnownVPNGateway: nil
    )
}

/// 已应用的主机路由记录
struct AppliedRoute: Identifiable, Hashable, Sendable {
    var id: String { "\(destination)|\(mode.rawValue)" }
    let destination: String
    let mode: RouteMode
    let processName: String
    let via: String
}

enum AppError: LocalizedError {
    case noVPN
    case noLocalGateway
    case privilegeDenied
    case routeFailed(String)
    case shell(String)

    var errorDescription: String? {
        switch self {
        case .noVPN: return "未检测到 VPN 接口。请先连接 VPN。"
        case .noLocalGateway: return "未检测到本地网关。"
        case .privilegeDenied: return "需要管理员权限才能修改路由表。"
        case .routeFailed(let s): return "路由操作失败：\(s)"
        case .shell(let s): return s
        }
    }
}

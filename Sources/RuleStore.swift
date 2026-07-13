import Foundation

/// 持久化路由规则与全局默认
final class RuleStore: @unchecked Sendable {
    static let shared = RuleStore()

    private let defaultsKey = "processroute.rules"
    private let defaultModeKey = "processroute.defaultMode"
    private let queue = DispatchQueue(label: "processroute.rulestore")

    private init() {}

    func load() -> [RouteRule] {
        queue.sync {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
            return (try? JSONDecoder().decode([RouteRule].self, from: data)) ?? []
        }
    }

    func save(_ rules: [RouteRule]) {
        queue.sync {
            if let data = try? JSONEncoder().encode(rules) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// 未单独指定规则的进程走什么：system=跟随系统，vpn/local=强制
    func loadDefaultMode() -> RouteMode {
        queue.sync {
            guard let raw = UserDefaults.standard.string(forKey: defaultModeKey),
                  let mode = RouteMode(rawValue: raw)
            else {
                return .system
            }
            return mode
        }
    }

    func saveDefaultMode(_ mode: RouteMode) {
        queue.sync {
            UserDefaults.standard.set(mode.rawValue, forKey: defaultModeKey)
        }
    }

    func upsert(_ rule: RouteRule, into rules: inout [RouteRule]) {
        if let idx = rules.firstIndex(where: { $0.matchKey == rule.matchKey }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        save(rules)
    }

    func remove(id: UUID, from rules: inout [RouteRule]) {
        rules.removeAll { $0.id == id }
        save(rules)
    }

    func setMode(_ mode: RouteMode, matchKey: String, processName: String, rules: inout [RouteRule]) {
        // 归一化：尽量用 Bundle ID，避免路径/Helper 名造成多条规则
        let key = matchKey
        if mode == .system {
            // 清掉同一应用可能留下的旧 key（路径 / 名称）
            rules.removeAll {
                $0.matchKey == key
                    || ProcessMonitor.namesBelongToSameApp($0.processName, processName)
            }
            save(rules)
            return
        }
        // 若已有同名应用规则，覆盖而不是新增
        if let idx = rules.firstIndex(where: {
            $0.matchKey == key || ProcessMonitor.namesBelongToSameApp($0.processName, processName)
        }) {
            rules[idx].matchKey = key
            rules[idx].processName = processName
            rules[idx].mode = mode
            rules[idx].enabled = true
            save(rules)
            return
        }
        let rule = RouteRule(processName: processName, matchKey: key, mode: mode, enabled: true)
        upsert(rule, into: &rules)
    }
}

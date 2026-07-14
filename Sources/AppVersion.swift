import Foundation

/// 版本号：年-月日-时分秒（月日合并无中间横杠），例如 `2026-0714-153045`
enum AppVersion {
    /// 编译期写入；构建脚本会覆盖为构建时刻
    static let buildDateFallback = "2026-0714-142132"

    /// 当前运行版本（优先 Info.plist，其次内置回退）
    static var current: String {
        if let s = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !s.isEmpty,
           s != "1.0",
           s != "1.3.0"
        {
            return normalize(s)
        }
        return normalize(buildDateFallback)
    }

    /// 展示用：`version 2026-0714-153045`
    static var display: String { "version \(current)" }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s = String(s.dropFirst())
        }
        s = s.replacingOccurrences(of: ":", with: "")

        // 20260714153045 → 2026-0714-153045
        if s.count == 14, s.allSatisfy(\.isNumber) {
            let y = s.prefix(4)
            let md = s.dropFirst(4).prefix(4)
            let t = s.suffix(6)
            return "\(y)-\(md)-\(t)"
        }
        // 20260714 → 2026-0714-000000
        if s.count == 8, s.allSatisfy(\.isNumber) {
            let y = s.prefix(4)
            let md = s.suffix(4)
            return "\(y)-\(md)-000000"
        }

        let parts = s.split(separator: "-").map(String.init)

        // 旧格式 YYYY-MM-DD-HHmmss → YYYY-MMDD-HHmmss
        if parts.count == 4,
           parts[0].count == 4,
           parts[1].count == 2,
           parts[2].count == 2,
           parts[3].count == 6,
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        {
            return "\(parts[0])-\(parts[1])\(parts[2])-\(parts[3])"
        }
        // 旧格式 YYYY-MM-DD → YYYY-MMDD-000000
        if parts.count == 3,
           parts[0].count == 4,
           parts[1].count == 2,
           parts[2].count == 2,
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        {
            return "\(parts[0])-\(parts[1])\(parts[2])-000000"
        }
        // YYYY-MM-DD-HH-mm-ss
        if parts.count == 6,
           parts[0].count == 4,
           parts[1].count == 2,
           parts[2].count == 2,
           parts[3].count == 2,
           parts[4].count == 2,
           parts[5].count == 2,
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        {
            return "\(parts[0])-\(parts[1])\(parts[2])-\(parts[3])\(parts[4])\(parts[5])"
        }
        // 已是 YYYY-MMDD-HHmmss 或 YYYY-MMDD
        if isDateVersion(s) {
            if parts.count == 2 {
                return "\(parts[0])-\(parts[1])-000000"
            }
            return s
        }
        return s
    }

    /// `YYYY-MMDD` 或 `YYYY-MMDD-HHmmss`
    static func isDateVersion(_ s: String) -> Bool {
        let parts = s.split(separator: "-").map(String.init)
        if parts.count == 2 {
            return parts[0].count == 4
                && parts[1].count == 4
                && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
        }
        if parts.count == 3 {
            // 新：YYYY-MMDD-HHmmss  或 旧：YYYY-MM-DD
            if parts[0].count == 4, parts[1].count == 4, parts[2].count == 6,
               parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
            {
                return true
            }
            if parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
               parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
            {
                return true
            }
        }
        if parts.count == 4 {
            // 旧：YYYY-MM-DD-HHmmss
            return parts[0].count == 4
                && parts[1].count == 2
                && parts[2].count == 2
                && parts[3].count == 6
                && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
        }
        return false
    }

    /// 比较用：统一 `YYYYMMDDHHmmss` 数字串
    static func sortKey(_ raw: String) -> String {
        let n = normalize(raw)
        let parts = n.split(separator: "-").map(String.init)
        // YYYY-MMDD-HHmmss
        if parts.count == 3, parts[0].count == 4, parts[1].count == 4, parts[2].count == 6 {
            return parts[0] + parts[1] + parts[2]
        }
        // YYYY-MMDD
        if parts.count == 2, parts[0].count == 4, parts[1].count == 4 {
            return parts[0] + parts[1] + "000000"
        }
        // 旧 YYYY-MM-DD-HHmmss
        if parts.count == 4 {
            return parts.joined()
        }
        // 旧 YYYY-MM-DD
        if parts.count == 3, parts[1].count == 2 {
            return parts[0] + parts[1] + parts[2] + "000000"
        }
        return n
    }

    /// remote > local → true（有更新）
    static func isRemoteNewer(_ remote: String, than local: String) -> Bool {
        let r = sortKey(remote)
        let l = sortKey(local)
        if r.allSatisfy(\.isNumber), l.allSatisfy(\.isNumber), r.count >= 8, l.count >= 8 {
            return r > l
        }
        let rn = normalize(remote)
        let ln = normalize(local)
        if isDateVersion(rn), !isDateVersion(ln) { return true }
        if !isDateVersion(rn), isDateVersion(ln) { return false }
        return rn != ln && !rn.isEmpty
    }
}

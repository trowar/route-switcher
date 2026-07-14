import Foundation

/// 版本号：年-月日，例如 `2026-07-14`
enum AppVersion {
    /// 编译期写入；构建脚本会覆盖为当天日期
    static let buildDateFallback = "2026-07-14"

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

    /// 展示用：`版本 2026-07-14`
    static var display: String { "版本 \(current)" }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s = String(s.dropFirst())
        }
        // 20260714 → 2026-07-14
        if s.count == 8, s.allSatisfy(\.isNumber) {
            let y = s.prefix(4)
            let m = s.dropFirst(4).prefix(2)
            let d = s.suffix(2)
            return "\(y)-\(m)-\(d)"
        }
        // 已是 YYYY-MM-DD
        if isDateVersion(s) { return s }
        return s
    }

    static func isDateVersion(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return false }
        return true
    }

    /// remote > local → true（有更新）
    static func isRemoteNewer(_ remote: String, than local: String) -> Bool {
        let r = normalize(remote)
        let l = normalize(local)
        if isDateVersion(r), isDateVersion(l) {
            return r > l // ISO 日期字符串可直接比较
        }
        // 非日期：不相等且 remote 非空则视为可更新（避免旧 semver 干扰）
        if isDateVersion(r), !isDateVersion(l) { return true }
        if !isDateVersion(r), isDateVersion(l) { return false }
        return r != l && !r.isEmpty
    }
}

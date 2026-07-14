import Foundation
import AppKit

/// 启动时向 GitHub Releases 查询新版本，并支持下载替换本 App
enum UpdateChecker {
    static let repoOwner = "trowar"
    static let repoName = "route-switcher"
    static let releasesAPI =
        "https://api.github.com/repos/trowar/route-switcher/releases/latest"
    static let releasesPage =
        "https://github.com/trowar/route-switcher/releases/latest"

    struct RemoteRelease: Sendable {
        let tag: String
        let version: String
        let htmlURL: String
        let downloadURL: String?
        let publishedAt: String?
        let name: String?
    }

    struct CheckResult: Sendable {
        let updateAvailable: Bool
        let localVersion: String
        let remote: RemoteRelease?
        let message: String
    }

    // MARK: - Check

    nonisolated static func check() async -> CheckResult {
        let local = AppVersion.current
        do {
            guard let remote = try await fetchLatestRelease() else {
                return CheckResult(
                    updateAvailable: false,
                    localVersion: local,
                    remote: nil,
                    message: "未能解析 GitHub 最新版本"
                )
            }
            // 优先用 tag 中的日期版本；否则用 published_at 的日期
            var remoteVer = AppVersion.normalize(remote.tag)
            if !AppVersion.isDateVersion(remoteVer),
               let pub = remote.publishedAt,
               let day = dateString(fromISO: pub)
            {
                remoteVer = day
            }
            let newer = AppVersion.isRemoteNewer(remoteVer, than: local)
            let adjusted = RemoteRelease(
                tag: remote.tag,
                version: remoteVer,
                htmlURL: remote.htmlURL,
                downloadURL: remote.downloadURL,
                publishedAt: remote.publishedAt,
                name: remote.name
            )
            return CheckResult(
                updateAvailable: newer,
                localVersion: local,
                remote: adjusted,
                message: newer
                    ? "发现新版本 \(remoteVer)（当前 \(local)）"
                    : "已是最新版本 \(local)"
            )
        } catch {
            return CheckResult(
                updateAvailable: false,
                localVersion: local,
                remote: nil,
                message: "检查更新失败：\(error.localizedDescription)"
            )
        }
    }

    nonisolated private static func fetchLatestRelease() async throws -> RemoteRelease? {
        guard let url = URL(string: releasesAPI) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("route-switcher-updater", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tag = (obj["tag_name"] as? String) ?? ""
        let html = (obj["html_url"] as? String) ?? releasesPage
        let name = obj["name"] as? String
        let published = obj["published_at"] as? String
        var download: String?
        if let assets = obj["assets"] as? [[String: Any]] {
            // 优先 RouteSwitcher.app.zip，其次任意 .zip
            for a in assets {
                if let n = a["name"] as? String,
                   n == "RouteSwitcher.app.zip",
                   let u = a["browser_download_url"] as? String
                {
                    download = u
                    break
                }
            }
            if download == nil {
                for a in assets {
                    if let n = a["name"] as? String, n.hasSuffix(".zip"),
                       let u = a["browser_download_url"] as? String
                    {
                        download = u
                        break
                    }
                }
            }
        }
        return RemoteRelease(
            tag: tag,
            version: AppVersion.normalize(tag),
            htmlURL: html,
            downloadURL: download,
            publishedAt: published,
            name: name
        )
    }

    nonisolated private static func dateString(fromISO iso: String) -> String? {
        // 2026-07-14T05:25:01Z
        let prefix = String(iso.prefix(10))
        return AppVersion.isDateVersion(prefix) ? prefix : nil
    }

    // MARK: - Download & replace

    enum UpdateError: LocalizedError {
        case noDownloadURL
        case downloadFailed(String)
        case unzipFailed
        case appNotFoundInZip
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDownloadURL: return "Release 中没有可下载的 .zip"
            case .downloadFailed(let s): return "下载失败：\(s)"
            case .unzipFailed: return "解压失败"
            case .appNotFoundInZip: return "压缩包内未找到 .app"
            case .replaceFailed(let s): return "替换失败：\(s)"
            }
        }
    }

    /// 下载 zip → 解压 → 替换当前 .app → 重启
    @MainActor
    static func downloadAndReplace(remote: RemoteRelease) async throws {
        guard let urlStr = remote.downloadURL, let url = URL(string: urlStr) else {
            // 没有资源则打开网页
            if let page = URL(string: remote.htmlURL) {
                NSWorkspace.shared.open(page)
            }
            throw UpdateError.noDownloadURL
        }

        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("route-switcher-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        let zipURL = tmpRoot.appendingPathComponent("update.zip")
        let extractDir = tmpRoot.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // 下载
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("route-switcher-updater", forHTTPHeaderField: "User-Agent")
        let (tmpFile, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
        }
        if fm.fileExists(atPath: zipURL.path) { try fm.removeItem(at: zipURL) }
        try fm.moveItem(at: tmpFile, to: zipURL)

        // 解压（ditto 保留资源分叉/权限）
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.unzipFailed }

        guard let newApp = findAppBundle(in: extractDir) else {
            throw UpdateError.appNotFoundInZip
        }

        let targetApp = runningAppURL()
        // 替换目标：优先当前 bundle；否则桌面
        let dest: URL = {
            if let targetApp, targetApp.pathExtension == "app" {
                return targetApp
            }
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/路由切换器.app")
        }()

        // 若目标就是当前正在运行的 App，先拷到旁路，退出后再原子替换并重启
        let replacingSelf: Bool = {
            guard let running = runningAppURL() else { return false }
            return running.standardizedFileURL.path == dest.standardizedFileURL.path
        }()

        if replacingSelf {
            try scheduleReplaceAfterQuit(from: newApp, to: dest)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        } else {
            try replaceApp(from: newApp, to: dest)
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", dest.path]
            try? xattr.run()
            xattr.waitUntilExit()
            NSWorkspace.shared.open(dest)
        }
    }

    /// 写临时脚本：等本进程退出后 ditto 覆盖并 open
    nonisolated private static func scheduleReplaceAfterQuit(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        // 把新 app 放到临时目录持久位置（脚本里再删）
        let hold = fm.temporaryDirectory
            .appendingPathComponent("route-switcher-hold-\(UUID().uuidString).app")
        try? fm.removeItem(at: hold)
        try fm.copyItem(at: src, to: hold)

        let scriptURL = fm.temporaryDirectory
            .appendingPathComponent("route-switcher-apply-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/zsh
        set +e
        SRC=\(shellQuote(hold.path))
        DEST=\(shellQuote(dest.path))
        # 等旧进程退出（最多 30s）
        for i in {1..60}; do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.5
        done
        sleep 0.3
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/xattr -cr "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        /bin/rm -rf "$SRC"
        /bin/rm -f -- \(shellQuote(scriptURL.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [scriptURL.path]
        // 脱离当前进程组，避免随 App 退出被杀
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 仅打开 GitHub 发布页 / 下载链接
    @MainActor
    static func openDownloadPage(remote: RemoteRelease) {
        if let s = remote.downloadURL, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
            return
        }
        if let u = URL(string: remote.htmlURL) {
            NSWorkspace.shared.open(u)
        } else if let u = URL(string: releasesPage) {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: - Helpers

    nonisolated private static func findAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                candidates.append(url)
                enumerator.skipDescendants()
            }
        }
        // 优先中文名
        if let cn = candidates.first(where: { $0.lastPathComponent == "路由切换器.app" }) {
            return cn
        }
        if let en = candidates.first(where: { $0.lastPathComponent == "RouteSwitcher.app" }) {
            return en
        }
        return candidates.first
    }

    nonisolated private static func runningAppURL() -> URL? {
        if let url = Bundle.main.bundleURL as URL?, url.pathExtension == "app" {
            return url.standardizedFileURL
        }
        return nil
    }

    nonisolated private static func replaceApp(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        let parent = dest.deletingLastPathComponent()
        let destName = dest.lastPathComponent
        let staging = parent.appendingPathComponent(".~\(destName).new")
        let backup = parent.appendingPathComponent(".~\(destName).old")

        // 清理残留
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: backup)

        // 先拷到同目录临时名
        try fm.copyItem(at: src, to: staging)

        if fm.fileExists(atPath: dest.path) {
            // 旧版移走再换上
            do {
                try fm.moveItem(at: dest, to: backup)
            } catch {
                // 可能正在运行无法移动：用 ditto 覆盖
                try? fm.removeItem(at: staging)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = [src.path, dest.path]
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    throw UpdateError.replaceFailed("ditto 覆盖失败")
                }
                return
            }
            do {
                try fm.moveItem(at: staging, to: dest)
                try? fm.removeItem(at: backup)
            } catch {
                // 回滚
                try? fm.removeItem(at: staging)
                if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: backup, to: dest)
                }
                throw UpdateError.replaceFailed(error.localizedDescription)
            }
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
    }
}

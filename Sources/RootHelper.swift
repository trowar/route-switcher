import Foundation
import Darwin

/// 以 root 运行的轻量守护：监听 Unix socket，仅执行允许的 route 命令。
enum RootHelper {
    static let argFlag = "--root-helper"

    static var isHelperMode: Bool {
        CommandLine.arguments.contains(argFlag)
    }

    static func socketPath(forOwnerUID uid: uid_t) -> String {
        "/tmp/processroute-helper-\(uid).sock"
    }

    static func logPath() -> String {
        "/tmp/processroute-helper.log"
    }

    static func ownerUIDFromArgs() -> uid_t {
        if let idx = CommandLine.arguments.firstIndex(of: "--owner-uid"),
           idx + 1 < CommandLine.arguments.count,
           let v = uid_t(CommandLine.arguments[idx + 1])
        {
            return v
        }
        return getuid()
    }

    /// 填充 sockaddr_un.sun_path
    static func fillUnixAddress(_ path: String, addr: inout sockaddr_un) -> Bool {
        addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let chars = Array(path.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard chars.count <= maxLen else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.bindMemory(to: UInt8.self).initialize(repeating: 0)
            for (i, b) in chars.enumerated() where i < raw.count {
                raw[i] = UInt8(bitPattern: b)
            }
        }
        return true
    }

    static func socklen(for path: String) -> socklen_t {
        // SUN_LEN 近似：family + path + NUL
        socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + path.utf8.count + 1)
    }

    /// root 进程入口
    static func run() {
        // 把 stdout/stderr 也落到日志，便于排查
        let log = logPath()
        freopen(log, "a", stdout)
        freopen(log, "a", stderr)
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        fputs("processroute-helper: boot pid=\(getpid()) euid=\(geteuid())\n", stderr)

        guard geteuid() == 0 else {
            fputs("processroute-helper: must run as root\n", stderr)
            exit(1)
        }

        let ownerUID = ownerUIDFromArgs()
        let path = socketPath(forOwnerUID: ownerUID)
        fputs("processroute-helper: socket=\(path) owner=\(ownerUID)\n", stderr)

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("processroute-helper: socket() failed errno=\(errno)\n", stderr)
            exit(1)
        }

        var addr = sockaddr_un()
        guard fillUnixAddress(path, addr: &addr) else {
            fputs("processroute-helper: path too long\n", stderr)
            exit(1)
        }

        let len = socklen(for: path)
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len)
            }
        }
        guard bindOK == 0 else {
            fputs("processroute-helper: bind failed errno=\(errno) path=\(path)\n", stderr)
            exit(1)
        }

        chmod(path, 0o777)
        guard listen(fd, 16) == 0 else {
            fputs("processroute-helper: listen failed errno=\(errno)\n", stderr)
            exit(1)
        }

        let pidPath = path + ".pid"
        try? "\(getpid())\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
        chmod(pidPath, 0o666)

        fputs("processroute-helper: READY on \(path)\n", stderr)

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                fputs("processroute-helper: accept errno=\(errno)\n", stderr)
                break
            }
            handleClient(client)
            close(client)
        }

        close(fd)
        unlink(path)
        unlink(pidPath)
    }

    private static func handleClient(_ client: Int32) {
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 8192)

        while true {
            let n = read(client, &tmp, tmp.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: tmp[0..<n])
            if processBuffer(&buffer, client: client) {
                return
            }
        }
    }

    /// 返回 true → helper 进程退出
    @discardableResult
    private static func processBuffer(_ buffer: inout Data, client: Int32) -> Bool {
        guard var text = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll()
            reply(client, "ERR bad encoding\n")
            return false
        }

        // 数据还不含换行则等待更多
        if !text.contains("\n") {
            return false
        }

        while let range = text.range(of: "\n") {
            let line = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[range.upperBound...])
            if line.isEmpty { continue }

            if line == "PING" {
                reply(client, "PONG\n")
                continue
            }
            if line == "QUIT" {
                reply(client, "BYE\n")
                buffer = Data(text.utf8)
                // 稍后再退，确保响应发出
                usleep(50_000)
                exit(0)
            }
            if line == "RUN" {
                var scriptLines: [String] = []
                var rest = text
                var foundEnd = false
                while let r = rest.range(of: "\n") {
                    let l = String(rest[..<r.lowerBound])
                    rest = String(rest[r.upperBound...])
                    let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t == "END" {
                        foundEnd = true
                        break
                    }
                    scriptLines.append(l)
                }
                if !foundEnd {
                    buffer = Data(("RUN\n" + text).utf8)
                    return false
                }
                text = rest
                reply(client, runScript(scriptLines))
                continue
            }

            if isAllowedRouteCommand(line) {
                reply(client, runScript([line]))
            } else {
                reply(client, "ERR command not allowed: \(line)\n")
            }
        }

        buffer = Data(text.utf8)
        return false
    }

    private static func runScript(_ lines: [String]) -> String {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard isAllowedRouteCommand(line) else {
                return "ERR not allowed: \(line)\n"
            }
            _ = runShell(line)
        }
        return "OK\n"
    }

    private static func isAllowedRouteCommand(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("/sbin/route ") else { return false }
        if t.contains(";") || t.contains("`") || t.contains("$(") || t.contains("${") {
            return false
        }
        if t.contains("\n") || t.contains("\r") { return false }
        if t.contains("|") {
            if !t.contains("|| true") && !t.contains("||true") {
                return false
            }
        }
        // 允许：add/delete host 路由，以及恢复默认网关（OpenVPN 断开后）
        let isHost = t.contains(" -host ")
        let isDefault = t.contains(" default") || t.contains(" default ")
        let isAddOrDelete = t.contains(" add") || t.contains(" delete")
        guard isAddOrDelete else { return false }
        guard isHost || isDefault else { return false }

        // default 命令只允许纯网关 IP，禁止任意参数注入
        if isDefault && !isHost {
            // 例如: /sbin/route -n add default 192.168.0.1
            //       /sbin/route -n delete default 192.168.0.1 2>/dev/null || true
            let stripped = t
                .replacingOccurrences(of: "2>/dev/null", with: "")
                .replacingOccurrences(of: "|| true", with: "")
                .replacingOccurrences(of: "||true", with: "")
            let tokens = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 3, tokens[0] == "/sbin/route" else { return false }
            // 所有 token 只能是 route 标志、default、IPv4
            for tok in tokens.dropFirst() {
                if tok == "-n" || tok == "add" || tok == "delete" || tok == "default" {
                    continue
                }
                if isIPv4Token(tok) { continue }
                return false
            }
        }
        return true
    }

    private static func isIPv4Token(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let n = Int(p), (0...255).contains(n) else { return false }
            return true
        }
    }

    private static func runShell(_ command: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    private static func reply(_ client: Int32, _ message: String) {
        message.withCString { ptr in
            _ = write(client, ptr, strlen(ptr))
        }
    }
}

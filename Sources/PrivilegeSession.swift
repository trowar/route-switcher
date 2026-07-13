import Foundation
import Darwin

/// 一次性提权：首次弹出管理员密码启动 root helper，之后经 socket 发命令不再要密码。
actor PrivilegeSession {
    static let shared = PrivilegeSession()

    private var ready = false
    private let ownerUID: uid_t = getuid()

    private var socketPath: String {
        RootHelper.socketPath(forOwnerUID: ownerUID)
    }

    private var logPath: String {
        RootHelper.logPath()
    }

    func isReady() async -> Bool {
        if ready, await ping() { return true }
        ready = await ping()
        return ready
    }

    func ensurePrivileged() async throws {
        if await isReady() { return }

        try startHelperOnce()

        // admin 脚本里已经等过 socket；这里再确认
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if await ping() {
                ready = true
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let logTail = (try? String(contentsOfFile: logPath, encoding: .utf8))
            .map { String($0.suffix(800)) } ?? "(无日志)"
        throw AppError.shell(
            """
            提权助手启动失败（密码可能已正确，但是助手进程没起来）。
            日志末尾：
            \(logTail)
            """
        )
    }

    func runRouteScript(_ script: String) async throws {
        try await ensurePrivileged()
        let lines = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var payload = "RUN\n"
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            payload += t + "\n"
        }
        payload += "END\n"
        let response = try send(payload)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("OK") { return }
        if trimmed.hasPrefix("ERR") {
            throw AppError.routeFailed(trimmed)
        }
        if trimmed.isEmpty {
            throw AppError.shell("提权助手无响应，请点刷新重新授权")
        }
    }

    func shutdownHelper() async {
        guard await ping() else { return }
        _ = try? send("QUIT\n")
        ready = false
    }

    // MARK: - Start helper

    /// 通过管理员权限启动 helper。关键点：
    /// - 不用 nohup（在 osascript 环境下会失败）
    /// - 用 python3 start_new_session 脱离会话，避免父进程结束带走子进程
    /// - 在提权脚本内等待 socket 就绪，失败时直接返回错误
    private func startHelperOnce() throws {
        let exe = resolveExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw AppError.shell("找不到可执行文件：\(exe)")
        }

        // 启动脚本写到固定路径，避免 osascript 转义地狱
        let launcher = "/tmp/processroute-launch-helper.py"
        let py = """
        #!/usr/bin/env python3
        import os, sys, time, subprocess, signal

        exe = sys.argv[1]
        uid = sys.argv[2]
        sock = sys.argv[3]
        log_path = sys.argv[4]

        def log(msg):
            with open(log_path, "a") as f:
                f.write(msg + "\\n")

        log("=== launch %s ===" % time.strftime("%Y-%m-%d %H:%M:%S"))
        log("exe=%s uid=%s euid=%s" % (exe, uid, os.geteuid()))

        # 清旧进程 / 旧 socket
        try:
            subprocess.call(["/usr/bin/pkill", "-f", "--root-helper"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        time.sleep(0.15)
        for p in (sock, sock + ".pid"):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass

        if os.geteuid() != 0:
            log("ERROR: not root")
            sys.exit(2)

        if not os.path.isfile(exe) or not os.access(exe, os.X_OK):
            log("ERROR: exe not executable: " + exe)
            sys.exit(3)

        logf = open(log_path, "a")
        # 新会话启动，父 python 退出后 helper 仍存活
        proc = subprocess.Popen(
            [exe, "--root-helper", "--owner-uid", uid],
            stdin=subprocess.DEVNULL,
            stdout=logf,
            stderr=logf,
            start_new_session=True,
            close_fds=True,
        )
        log("spawned pid=%s" % proc.pid)

        # 等 socket
        for i in range(80):
            if os.path.exists(sock):
                # 简单校验是 socket
                import stat
                mode = os.stat(sock).st_mode
                if stat.S_ISSOCK(mode):
                    log("socket ready after %.1fs" % (i * 0.1))
                    sys.exit(0)
            # 子进程是否已退出
            ret = proc.poll()
            if ret is not None:
                log("helper exited early code=%s" % ret)
                sys.exit(4)
            time.sleep(0.1)

        log("timeout waiting for socket")
        try:
            os.kill(proc.pid, signal.SIGTERM)
        except Exception:
            pass
        sys.exit(5)
        """

        do {
            try py.write(toFile: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: launcher
            )
        } catch {
            throw AppError.shell("无法写入启动脚本：\(error.localizedDescription)")
        }

        // 找可用的 python3（/usr/bin/python3 在未装 Xcode CLT 时可能是无效 stub）
        let python = resolvePython3()
        let cmd: String
        if let python {
            cmd = """
            '\(python)' '\(launcher)' '\(exe)' '\(ownerUID)' '\(socketPath)' '\(logPath)'
            """
        } else {
            // bash 回退：trap HUP + 后台启动（不用 nohup）
            cmd = """
            /bin/bash -c '
            LOG="\(logPath)"
            EXE="\(exe)"
            SOCK="\(socketPath)"
            UID_N="\(ownerUID)"
            echo "=== bash launch $(date) ===" >>"$LOG"
            /usr/bin/pkill -f -- --root-helper >/dev/null 2>&1 || true
            /bin/rm -f "$SOCK" "$SOCK.pid"
            (
              trap "" HUP
              exec < /dev/null
              exec >>"$LOG" 2>&1
              echo "starting helper"
              exec "$EXE" --root-helper --owner-uid "$UID_N"
            ) &
            CHILD=$!
            echo "child=$CHILD" >>"$LOG"
            for i in $(seq 1 80); do
              if [ -S "$SOCK" ]; then echo "socket ready" >>"$LOG"; exit 0; fi
              if ! kill -0 $CHILD 2>/dev/null; then echo "child died" >>"$LOG"; exit 4; fi
              /bin/sleep 0.1
            done
            echo "timeout" >>"$LOG"
            exit 5
            '
            """
        }

        do {
            _ = try Shell.runAdmin(cmd)
        } catch {
            let logTail = (try? String(contentsOfFile: logPath, encoding: .utf8))
                .map { String($0.suffix(600)) } ?? ""
            let msg = error.localizedDescription
            if msg.contains("privilege") || msg.contains("canceled") || msg.contains("取消") {
                throw error
            }
            throw AppError.shell(
                """
                启动提权助手失败：\(msg)
                \(logTail.isEmpty ? "" : "日志：\n" + logTail)
                """
            )
        }
    }

    private func resolvePython3() -> String? {
        let candidates = [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            // 过滤 Xcode stub（运行会提示 install）
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-c", "import sys; print(sys.version)"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 { return path }
            } catch {
                continue
            }
        }
        return nil
    }

    private func resolveExecutablePath() -> String {
        if let builtIn = Bundle.main.executablePath, !builtIn.isEmpty {
            return builtIn
        }
        return CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? "/usr/local/bin/ProcessRoute"
    }

    private func ping() async -> Bool {
        (try? send("PING\n"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "PONG"
    }

    private func send(_ payload: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.shell("无法创建本地套接字") }
        defer { close(fd) }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        guard RootHelper.fillUnixAddress(socketPath, addr: &addr) else {
            throw AppError.shell("socket 路径过长")
        }

        let len = RootHelper.socklen(for: socketPath)
        let conn = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, len)
            }
        }
        guard conn == 0 else {
            ready = false
            throw AppError.shell("无法连接提权助手（errno=\(errno)）")
        }

        try payload.withCString { ptr in
            let n = write(fd, ptr, strlen(ptr))
            if n < 0 { throw AppError.shell("写入提权助手失败") }
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let s = String(data: data, encoding: .utf8), s.contains("\n") {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

import Foundation

enum Shell {
    /// 有损解码：lsof 等工具在中文环境下可能混入非 UTF-8 字节，不能整段丢弃
    static func decodeOutput(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func run(
        _ command: String,
        timeout: TimeInterval = 20,
        requireZeroExit: Bool = false
    ) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 不用 login shell，避免慢/污染环境
        process.arguments = ["-c", command]
        process.standardOutput = stdout
        process.standardError = stderr
        // 保证能找到系统工具
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["LC_ALL"] = "C"
        process.environment = env

        try process.run()

        let outBox = OutputBox()
        let errBox = OutputBox()
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading

        outHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outBox.append(data)
            }
        }
        errHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errBox.append(data)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            throw AppError.shell("命令超时: \(command)")
        }

        Thread.sleep(forTimeInterval: 0.05)
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        outBox.append(outHandle.readDataToEndOfFile())
        errBox.append(errHandle.readDataToEndOfFile())

        let out = decodeOutput(outBox.dataCopy)
        let err = decodeOutput(errBox.dataCopy)

        if requireZeroExit && process.terminationStatus != 0 {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                throw AppError.shell(message)
            }
            throw AppError.shell("退出码 \(process.terminationStatus): \(command)")
        }
        return out
    }

    /// 管理员权限执行：写入临时脚本再跑
    @discardableResult
    static func runAdmin(_ command: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let scriptURL = dir.appendingPathComponent("processroute-\(UUID().uuidString).sh")
        let script = """
        #!/bin/zsh
        export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        set +e
        \(command)
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let path = scriptURL.path
        let escapedPath = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"/bin/zsh \\\"\(escapedPath)\\\"\" with administrator privileges"
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = decodeOutput(stdout.fileHandleForReading.readDataToEndOfFile())
        let err = decodeOutput(stderr.fileHandleForReading.readDataToEndOfFile())

        if process.terminationStatus != 0 {
            let message = (err + "\n" + out).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("canceled")
                || message.localizedCaseInsensitiveContains("cancelled")
                || message.localizedCaseInsensitiveContains("User canceled")
                || message.contains("-128")
            {
                throw AppError.privilegeDenied
            }
            throw AppError.shell(message.isEmpty ? "管理员命令失败" : message)
        }
        return out
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var dataCopy: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

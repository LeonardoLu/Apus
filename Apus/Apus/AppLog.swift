//
//  AppLog.swift
//  Apus
//

import Foundation

/// 将日志写入 Application Support 下 `Logs` 目录中的文件（与控制台 `NSLog` 同步输出便于调试）。
enum AppLog {
    private static let queue = DispatchQueue(label: "\(VMConstants.bundleID).AppLog")

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static var fileHandle: FileHandle?

    /// 打开或创建日志文件（在 `VMConstants.ensureDirectoriesExist()` 之后调用）。
    static func prepare() {
        queue.sync {
            openFileIfNeeded()
        }
    }

    /// 正常退出前刷新并关闭文件句柄。
    static func flushAndClose() {
        queue.sync {
            do {
                try fileHandle?.synchronize()
                try fileHandle?.close()
            } catch {
                NSLog("AppLog: 关闭日志文件失败: \(error.localizedDescription)")
            }
            fileHandle = nil
        }
    }

    /// 当前正在写入的日志文件 URL（用于排障或「在 Finder 中显示」）。
    static var logFileURL: URL {
        VMConstants.logFileURL
    }

    /// 写入一行日志到文件，并调用 `NSLog` 输出到系统日志。
    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let shortFile = (file as NSString).lastPathComponent
        let stamp = timestampFormatter.string(from: Date())
        let text = "\(stamp) [\(shortFile):\(line)] \(message)"
        NSLog("%@", text)
        let lineData = (text + "\n").data(using: .utf8)
        queue.async {
            openFileIfNeeded()
            guard let data = lineData, let handle = fileHandle else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                NSLog("AppLog: 写入日志失败: \(error.localizedDescription)")
            }
        }
    }

    private static func openFileIfNeeded() {
        guard fileHandle == nil else { return }
        let url = VMConstants.logFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: VMConstants.logsDirectoryURL, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: nil)
            }
            fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle?.seekToEnd()
        } catch {
            NSLog("AppLog: 无法打开日志文件 \(url.path): \(error.localizedDescription)")
            fileHandle = nil
        }
    }
}

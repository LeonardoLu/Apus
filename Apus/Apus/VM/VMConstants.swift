//
//  VMConstants.swift
//  Apus
//

import Foundation

enum VMConstants {
    /// 使用 bundle identifier 作为 app 目录名
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.github.leonardolu.Apus"

    /// ~/Library/Application Support/com.github.leonardolu.Apus/
    static let appSupportURL: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(bundleID, isDirectory: true)
    }()

    /// ~/Library/Application Support/com.github.leonardolu.Apus/VMs/
    static let vmsDirectoryURL = appSupportURL.appendingPathComponent("VMs", isDirectory: true)

    /// ~/Library/Application Support/com.github.leonardolu.Apus/Downloads/
    static let downloadsDirectoryURL = appSupportURL.appendingPathComponent(
        "Downloads", isDirectory: true)

    /// 共享的 IPSW 下载路径（向后兼容的默认路径）
    static let restoreImageURL = downloadsDirectoryURL.appendingPathComponent("RestoreImage.ipsw")

    /// 根据 macOS 版本生成 IPSW 文件名（如 macOS_15.2_24C101.ipsw）
    static func ipswFileName(majorVersion: Int, minorVersion: Int, patchVersion: Int, buildVersion: String) -> String {
        var name = "macOS_\(majorVersion).\(minorVersion)"
        if patchVersion > 0 {
            name += ".\(patchVersion)"
        }
        name += "_\(buildVersion).ipsw"
        return name
    }

    /// 根据版本信息生成完整的 IPSW 下载路径
    static func ipswURL(majorVersion: Int, minorVersion: Int, patchVersion: Int, buildVersion: String) -> URL {
        let fileName = ipswFileName(
            majorVersion: majorVersion, minorVersion: minorVersion,
            patchVersion: patchVersion, buildVersion: buildVersion)
        return downloadsDirectoryURL.appendingPathComponent(fileName)
    }

    /// 在下载目录中查找已缓存的 IPSW 文件（优先返回最近修改的）
    static func findCachedIPSW() -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: downloadsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return contents
            .filter { $0.pathExtension.lowercased() == "ipsw" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return date1 > date2
            }
            .first
    }

    /// 确保 app 所需目录存在
    static func ensureDirectoriesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: vmsDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: downloadsDirectoryURL, withIntermediateDirectories: true)
    }

    // MARK: - 下载目录管理

    /// 预期的文件扩展名（.ipsw 文件均为预期下载文件）
    private static let expectedExtensions: Set<String> = ["ipsw"]

    /// 描述下载目录中的一个文件
    struct DownloadFileInfo: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let size: UInt64
    }

    /// 获取下载目录中的多余文件（非 .ipsw 文件）
    static func getExtraDownloadFiles() -> [DownloadFileInfo] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: downloadsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return [] }

        return contents.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard !expectedExtensions.contains(ext) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { UInt64($0) } ?? 0
            return DownloadFileInfo(url: url, name: url.lastPathComponent, size: size)
        }
    }

    /// 获取下载目录中所有文件的信息
    static func getAllDownloadFiles() -> [DownloadFileInfo] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: downloadsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }

        return contents.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { UInt64($0) } ?? 0
            return DownloadFileInfo(url: url, name: url.lastPathComponent, size: size)
        }
    }

    /// 清除下载目录中的多余文件
    static func cleanExtraDownloadFiles() {
        for file in getExtraDownloadFiles() {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// 清除整个下载目录的内容（包括 IPSW 缓存），并重新创建空目录
    static func cleanDownloadsDirectory() {
        let fm = FileManager.default
        try? fm.removeItem(at: downloadsDirectoryURL)
        try? fm.createDirectory(at: downloadsDirectoryURL, withIntermediateDirectories: true)
    }
}

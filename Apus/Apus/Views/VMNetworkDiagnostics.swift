//
//  VMNetworkDiagnostics.swift
//  Apus
//

import SwiftUI
import AppKit

// MARK: - 网络信息弹出面板

struct VMNetworkInfoPopover: View {
    let instance: VMInstance
    @State private var vmIPAddress: String?
    @State private var gatewayIP: String?
    @State private var isDetecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Label("网络信息", systemImage: "network")
                .font(.headline)

            Divider()

            // 网络模式
            networkInfoRow(
                label: "网络模式",
                value: instance.networkMode.displayName,
                icon: instance.networkMode == .bridged ? "network" : "wifi.router"
            )

            // MAC 地址
            if let mac = instance.macAddress {
                copyableRow(label: "MAC 地址", value: mac, icon: "barcode")
            }

            // VM IP
            HStack {
                Label("虚拟机 IP", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                if isDetecting && vmIPAddress == nil {
                    ProgressView()
                        .controlSize(.mini)
                    Text("检测中…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else if let ip = vmIPAddress {
                    Text(ip)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    copyButton(ip)
                } else {
                    Text("未检测到")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            // 网关 IP
            if let gw = gatewayIP {
                copyableRow(label: "网关 (宿主机)", value: gw, icon: "wifi.router")
            }

            Divider()

            // 使用提示
            VStack(alignment: .leading, spacing: 6) {
                Text("访问提示")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if let ip = vmIPAddress {
                    HStack(spacing: 4) {
                        Text("从宿主机 SSH 到 VM:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ssh user@\(ip)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let gw = gatewayIP {
                    HStack(spacing: 4) {
                        Text("从 VM 访问宿主机:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(gw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if vmIPAddress == nil && !isDetecting {
                    Text("VM 启动后需等待片刻，系统分配 IP 后即可检测到")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // 刷新按钮
            HStack {
                Spacer()
                Button {
                    detectNetworkInfo()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDetecting)
            }
        }
        .padding()
        .frame(minWidth: 340, maxWidth: 340, minHeight: 280, alignment: .top)
        .onAppear {
            detectNetworkInfo()
        }
    }

    // MARK: - 辅助视图

    private func networkInfoRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout)
        }
    }

    private func copyableRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            copyButton(value)
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("复制到剪贴板")
    }

    // MARK: - 网络检测

    private func detectNetworkInfo() {
        isDetecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ip = instance.macAddress.flatMap { VMNetworkHelper.detectIPAddress(forMAC: $0) }
            let gw = VMNetworkHelper.detectGatewayIP()
            DispatchQueue.main.async {
                vmIPAddress = ip
                gatewayIP = gw
                isDetecting = false
            }
        }
    }
}

// MARK: - 网络信息辅助工具

enum VMNetworkHelper {
    /// 通过 ARP 表查找 VM 的 IP 地址（根据 MAC 地址匹配）
    static func detectIPAddress(forMAC macAddress: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.log("[网络诊断] 执行 arp 失败: \(error.localizedDescription)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let targetMAC = normalizeMAC(macAddress)

        for line in output.components(separatedBy: "\n") {
            // ARP 输出格式: ? (192.168.64.2) at a6:64:b3:1d:7e:e0 on bridge100 ifscope [ethernet]
            let parts = line.components(separatedBy: " ")
            guard parts.count >= 4, parts[3] != "(incomplete)" else { continue }
            let arpMAC = normalizeMAC(parts[3])
            if arpMAC == targetMAC {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        }
        return nil
    }

    /// 获取宿主机网关 IP（bridge100 接口地址）
    static func detectGatewayIP() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["bridge100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.log("[网络诊断] 执行 ifconfig 失败: \(error.localizedDescription)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 2 {
                    return parts[1]
                }
            }
        }
        return nil
    }

    /// 规范化 MAC 地址：统一为小写、每段补全为两位十六进制
    private static func normalizeMAC(_ mac: String) -> String {
        mac.lowercased()
            .split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
    }
}

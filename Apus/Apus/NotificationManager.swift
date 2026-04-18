//
//  NotificationManager.swift
//  Apus
//

import Foundation
import UserNotifications

// MARK: - 通知类别

enum NotificationCategory: String {
    case downloadComplete = "downloadComplete"
    case installComplete = "installComplete"
    case vmError = "vmError"
    case vmStopped = "vmStopped"
}

// MARK: - 通知管理器

enum NotificationManager {

    // MARK: - UserDefaults Keys

    static let enabledKey = "notificationEnabled"
    static let downloadCompleteKey = "notifyDownloadComplete"
    static let installCompleteKey = "notifyInstallComplete"
    static let vmErrorKey = "notifyVMError"
    static let vmStoppedKey = "notifyVMStopped"
    static let soundEnabledKey = "notificationSoundEnabled"

    // MARK: - 内部代理

    private static let notificationDelegate = NotificationDelegateHandler()

    // MARK: - 初始化

    /// 注册默认值并设置代理
    static func setup() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            downloadCompleteKey: true,
            installCompleteKey: true,
            vmErrorKey: true,
            vmStoppedKey: false,
            soundEnabledKey: true,
        ])
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    // MARK: - 权限管理

    /// 请求通知权限
    static func requestPermission(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            DispatchQueue.main.async {
                completion?(granted)
            }
        }
    }

    /// 检查当前授权状态
    static func checkAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }

    // MARK: - 发送通知

    /// 发送本地通知
    static func send(title: String, body: String, category: NotificationCategory) {
        let defaults = UserDefaults.standard

        // 检查总开关
        guard defaults.bool(forKey: enabledKey) else { return }
        // 检查分类开关
        guard isCategoryEnabled(category) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue

        if defaults.bool(forKey: soundEnabledKey) {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // 立即发送
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 内部方法

    private static func isCategoryEnabled(_ category: NotificationCategory) -> Bool {
        let defaults = UserDefaults.standard
        switch category {
        case .downloadComplete: return defaults.bool(forKey: downloadCompleteKey)
        case .installComplete: return defaults.bool(forKey: installCompleteKey)
        case .vmError: return defaults.bool(forKey: vmErrorKey)
        case .vmStopped: return defaults.bool(forKey: vmStoppedKey)
        }
    }
}

// MARK: - 通知代理（支持前台展示通知）

private class NotificationDelegateHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

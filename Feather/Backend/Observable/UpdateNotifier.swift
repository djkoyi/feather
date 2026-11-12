//
//  UpdateNotifier.swift
//  Feather
//
//  Local notifications for available app updates (AltStore-style).
//

import Foundation
import UserNotifications
import UIKit
import OSLog

@MainActor
final class UpdateNotifier: NSObject, ObservableObject {
	static let shared = UpdateNotifier()

	nonisolated static let notificationsEnabledKey = "Feather.updateNotifications"

	private nonisolated static let _notifiedKey = "Feather.notifiedUpdateVersions"
	private nonisolated static let _categoryID = "FEATHER_APP_UPDATE"
	private nonisolated static let _updateActionID = "FEATHER_APP_UPDATE_NOW"
	private nonisolated static let _uuidInfoKey = "localUUID"

	private let _center = UNUserNotificationCenter.current()

	private override init() {
		super.init()
	}

	/// Must be called at launch so taps on notifications are routed to us.
	func configure() {
		_center.delegate = self

		let updateAction = UNNotificationAction(
			identifier: Self._updateActionID,
			title: .localized("Update"),
			options: [.foreground]
		)
		let category = UNNotificationCategory(
			identifier: Self._categoryID,
			actions: [updateAction],
			intentIdentifiers: []
		)
		_center.setNotificationCategories([category])
	}

	func requestAuthorizationIfNeeded() async {
		let settings = await _center.notificationSettings()
		guard settings.authorizationStatus == .notDetermined else { return }

		do {
			_ = try await _center.requestAuthorization(options: [.alert, .sound, .badge])
		} catch {
			Logger.misc.error("Notification authorization failed: \(error.localizedDescription)")
		}
	}

	/// Posts one notification per update that was not announced before
	/// (keyed by bundle identifier + remote version) and refreshes the badge.
	func notify(about updates: [AppUpdate]) async {
		let unique = _uniqueByBundle(updates)
		await _setBadge(unique.count)

		guard UserDefaults.standard.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true else {
			return
		}

		let settings = await _center.notificationSettings()
		guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
			return
		}

		var notified = Set(UserDefaults.standard.stringArray(forKey: Self._notifiedKey) ?? [])
		let fresh = unique.filter { !notified.contains(_notifiedToken(for: $0)) }

		for update in fresh {
			let content = UNMutableNotificationContent()
			content.title = .localized("Update Available")
			content.body = "\(update.appName) \(update.remoteVersion)"
			content.sound = .default
			content.categoryIdentifier = Self._categoryID
			content.threadIdentifier = "feather.updates"
			content.userInfo = [Self._uuidInfoKey: update.localUUID]

			let request = UNNotificationRequest(
				identifier: "feather.update.\(update.bundleIdentifier)",
				content: content,
				trigger: nil
			)

			do {
				try await _center.add(request)
				notified.insert(_notifiedToken(for: update))
			} catch {
				Logger.misc.error("Could not post update notification: \(error.localizedDescription)")
			}
		}

		UserDefaults.standard.set(Array(notified), forKey: Self._notifiedKey)
	}

	func clearDelivered(for bundleIdentifier: String) {
		_center.removeDeliveredNotifications(withIdentifiers: ["feather.update.\(bundleIdentifier)"])
	}

	func refreshBadge(count: Int) {
		Task { await _setBadge(count) }
	}

	private func _setBadge(_ count: Int) async {
		do {
			try await _center.setBadgeCount(count)
		} catch {
			Logger.misc.error("Could not set badge: \(error.localizedDescription)")
		}
	}

	private func _notifiedToken(for update: AppUpdate) -> String {
		"\(update.bundleIdentifier)|\(update.remoteVersion)"
	}

	/// Signed and imported copies of the same app produce the same update;
	/// announce it once.
	private func _uniqueByBundle(_ updates: [AppUpdate]) -> [AppUpdate] {
		var seen = Set<String>()
		return updates.filter { seen.insert($0.bundleIdentifier).inserted }
	}
}

// MARK: - UNUserNotificationCenterDelegate
extension UpdateNotifier: UNUserNotificationCenterDelegate {
	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .list, .sound]
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		let content = response.notification.request.content
		guard
			content.categoryIdentifier == Self._categoryID,
			let uuid = content.userInfo[Self._uuidInfoKey] as? String
		else {
			return
		}

		// Tapping the notification (or its "Update" action) starts the update:
		// download, sign with the same certificate and install.
		await AutoUpdater.shared.updateFromNotification(localUUID: uuid)
	}
}

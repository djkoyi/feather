//
//  UpdatesView.swift
//  Feather
//
//  Settings for automatic update checks, notifications and AltServer-style updates.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct UpdatesView: View {
	@AppStorage(UpdateManager.autoCheckEnabledKey) private var _autoCheck: Bool = true
	@AppStorage(UpdateNotifier.notificationsEnabledKey) private var _notifications: Bool = true
	@AppStorage(AutoUpdater.autoUpdateOnOpenKey) private var _autoUpdateOnOpen: Bool = false

	@ObservedObject private var _updateManager = UpdateManager.shared

	// MARK: Body
	var body: some View {
		NBList(.localized("Updates")) {
			Section {
				Toggle(.localized("Check Automatically"), systemImage: "arrow.triangle.2.circlepath", isOn: $_autoCheck)
				Toggle(.localized("Notify About Updates"), systemImage: "bell.badge", isOn: $_notifications)
					.disabled(!_autoCheck)
			} footer: {
				Text(.localized("Feather checks your sources when opened and periodically in the background. iOS decides when background checks run."))
			}

			Section {
				Toggle(.localized("Update When Opening Feather"), systemImage: "bolt.badge.clock", isOn: $_autoUpdateOnOpen)
			} footer: {
				Text(.localized("Updates are downloaded, signed with the same certificate and bundle identifier as the installed app, and installed. With the idevice installation method no confirmation is needed."))
			}

			Section {
				Button(.localized("Check Now"), systemImage: "arrow.clockwise") {
					Task {
						await UpdateNotifier.shared.requestAuthorizationIfNeeded()
						await _updateManager.checkForUpdatesUsingStorage(notify: true)
					}
				}
				.disabled(_updateManager.isChecking)
			} footer: {
				if let last = _updateManager.lastCheckedDate {
					Text(verbatim: .localized("Last checked: %@", arguments: last.formatted(date: .abbreviated, time: .shortened)))
				}
			}
		}
		.onChange(of: _autoCheck) { _ in
			#if !targetEnvironment(macCatalyst)
			UpdateRefreshScheduler.schedule()
			#endif
		}
		.onChange(of: _notifications) { enabled in
			guard enabled else { return }
			Task { await UpdateNotifier.shared.requestAuthorizationIfNeeded() }
		}
	}
}

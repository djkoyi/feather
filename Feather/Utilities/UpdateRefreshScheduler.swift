//
//  UpdateRefreshScheduler.swift
//  Feather
//
//  Periodic update checks in the background (BGAppRefreshTask).
//  iOS decides the exact time; we only ask for "not earlier than".
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks
import OSLog
import os

enum UpdateRefreshScheduler {
	private static let _minimumInterval: TimeInterval = 60 * 60 * 2
	private static var _isRegistered = false
	private static var _identifier: String {
		"\(Bundle.main.bundleIdentifier!).updateCheck"
	}

	/// Must be called before `application(_:didFinishLaunchingWithOptions:)` returns.
	static func register() {
		// Registering an identifier missing from Info.plist crashes the app
		// (happens when Feather is re-signed with another bundle identifier).
		let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
		guard permitted.contains(_identifier) else {
			Logger.misc.error("Background update checks disabled: \(_identifier) is not in BGTaskSchedulerPermittedIdentifiers")
			_isRegistered = false
			return
		}
		_isRegistered = true

		BGTaskScheduler.shared.register(forTaskWithIdentifier: _identifier, using: nil) { task in
			guard let task = task as? BGAppRefreshTask else {
				task.setTaskCompleted(success: false)
				return
			}
			_handle(task)
		}
	}

	static func schedule() {
		guard _isRegistered else { return }
		guard UpdateManager.isAutoCheckEnabled else {
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: _identifier)
			return
		}

		let request = BGAppRefreshTaskRequest(identifier: _identifier)
		request.earliestBeginDate = Date(timeIntervalSinceNow: _minimumInterval)
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			Logger.misc.error("Could not schedule update check: \(error.localizedDescription)")
		}
	}

	private static func _handle(_ task: BGAppRefreshTask) {
		schedule()
		
		// The task must be completed exactly once (expiration and normal end can race).
		let completed = OSAllocatedUnfairLock(initialState: false)
		let finish: @Sendable (Bool) -> Void = { success in
			let alreadyDone = completed.withLock { done -> Bool in
				defer { done = true }
				return done
			}
			if !alreadyDone {
				task.setTaskCompleted(success: success)
			}
		}
		
		let work = Task { @MainActor in
			await UpdateManager.shared.checkForUpdatesUsingStorage(notify: true)
			finish(true)
		}
		
		task.expirationHandler = {
			work.cancel()
			finish(false)
		}
	}
}

#endif

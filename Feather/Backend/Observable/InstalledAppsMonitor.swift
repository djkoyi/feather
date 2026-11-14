//
//  InstalledAppsMonitor.swift
//  Feather
//
//  Which signed apps of the library are on the device. iOS 26 does not let a
//  sandboxed app ask (LaunchServices answers "permission denied"), so, like
//  AltStore, Feather keeps its own record: an app is installed when Feather
//  installs it, and stops being installed when opening it fails.
//

import Foundation
import OSLog
import UIKit
import NimbleExtensions

@MainActor
final class InstalledAppsMonitor: ObservableObject {
	static let shared = InstalledAppsMonitor()
	
	private static let _installedKey = "Feather.installedIdentifiers"
	private static let _seededKey = "Feather.installedIdentifiersSeeded"
	
	@Published private(set) var installed: Set<String>
	
	private init() {
		installed = Set(UserDefaults.standard.stringArray(forKey: Self._installedKey) ?? [])
	}
	
	func isInstalled(_ identifier: String?) -> Bool {
		guard let identifier else { return false }
		return installed.contains(identifier)
	}
	
	/// First run: signed copies already in the library were signed to be
	/// installed, so they start as installed (a failed Open corrects it).
	func seedIfNeeded(signedIdentifiers: [String]) {
		guard !UserDefaults.standard.bool(forKey: Self._seededKey) else { return }
		UserDefaults.standard.set(true, forKey: Self._seededKey)
		_update(installed.union(signedIdentifiers))
	}
	
	func markInstalled(_ identifier: String?) {
		guard let identifier, !identifier.isEmpty else { return }
		_update(installed.union([identifier]))
	}
	
	func markRemoved(_ identifier: String?) {
		guard let identifier else { return }
		_update(installed.subtracting([identifier]))
	}
	
	/// Opens the app. If Feather is still in the foreground a moment later,
	/// iOS could not open it: it is no longer installed (`onMissing` runs).
	func open(_ identifier: String, onMissing: @escaping () -> Void) {
		let reported = UIApplication.openApp(with: identifier)
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			guard UIApplication.shared.applicationState == .active else { return }
			Logger.misc.notice("Open did not leave Feather (reported \(reported, privacy: .public)), marking as not installed: \(identifier, privacy: .public)")
			markRemoved(identifier)
			onMissing()
		}
	}
	
	private func _update(_ new: Set<String>) {
		guard new != installed else { return }
		installed = new
		UserDefaults.standard.set(Array(new).sorted(), forKey: Self._installedKey)
	}
}

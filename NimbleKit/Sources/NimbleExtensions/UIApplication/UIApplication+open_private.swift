//
//  UIApplication+open.swift
//  Feather
//
//  Created by samara on 21.04.2025.
//

import UIKit.UIApplication

extension UIApplication {
	/// Opens an app with an identifier
	/// - Parameter identifier: Application identifier
	static public func openApp(with identifier: String) {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" 			// LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="     			// defaultWorkspace
		let openSelectorBase64 = "b3BlbkFwcGxpY2F0aW9uV2l0aEJ1bmRsZUlEOg==" // openApplicationWithBundleID:
		
		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
			let openSelectorData = Data(base64Encoded: openSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let defaultSelector = String(data: defaultSelectorData, encoding: .utf8),
			let openSelector = String(data: openSelectorData, encoding: .utf8)
		else {
			return
		}
		
		guard
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else {
			return
		}
		
		_ = workspace.perform(NSSelectorFromString(openSelector), with: identifier)
	}
	
	/// Returns install progress for a bundle identifier (0.0 – 1.0)
	/// - Parameters:
	///   - identifier: Bundle identifier
	///   - synchronous: Whether the call should block
	/// - Returns: Progress value if available
	static public func installProgress(
		for identifier: String,
		makeSynchronous synchronous: Bool = true
	) -> Double? {

		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
		let progressSelectorBase64 = "aW5zdGFsbFByb2dyZXNzRm9yQnVuZGxlSUQ6bWFrZVN5bmNocm9ub3VzOg==" // installProgressForBundleID:makeSynchronous:

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
			let progressSelector = String(data: Data(base64Encoded: progressSelectorBase64)!, encoding: .utf8),
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else { return nil }

		let result = workspace.perform(
			NSSelectorFromString(progressSelector),
			with: identifier,
			with: synchronous
		)?.takeUnretainedValue()

		if let number = result as? Progress {
			return number.fractionCompleted
		}

		return nil
	}

	/// Returns the version (CFBundleShortVersionString) iOS reports for an installed app.
	/// - Parameter identifier: Bundle identifier
	/// - Returns: Installed version, or `nil` when the app is not installed or iOS does not expose it
	static public func installedVersion(for identifier: String) -> String? {
		let classNameBase64 = "TFNBcHBsaWNhdGlvblByb3h5" // LSApplicationProxy
		let proxySelectorBase64 = "YXBwbGljYXRpb25Qcm94eUZvcklkZW50aWZpZXI6" // applicationProxyForIdentifier:

		guard
			let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
			let proxySelector = String(data: Data(base64Encoded: proxySelectorBase64)!, encoding: .utf8),
			let proxyClass = NSClassFromString(className) as? NSObject.Type,
			proxyClass.responds(to: NSSelectorFromString(proxySelector)),
			let proxy = proxyClass.perform(
				NSSelectorFromString(proxySelector),
				with: identifier
			)?.takeUnretainedValue() as? NSObject
		else { return nil }

		if
			proxy.responds(to: NSSelectorFromString("isInstalled")),
			let installed = proxy.value(forKey: "isInstalled") as? Bool,
			!installed
		{
			return nil
		}

		guard
			proxy.responds(to: NSSelectorFromString("shortVersionString")),
			let version = proxy.value(forKey: "shortVersionString") as? String,
			!version.isEmpty
		else { return nil }

		return version
	}
}

//
//  AutoUpdater.swift
//  Feather
//
//  AltServer-style updates: download the new version from the source,
//  re-sign it with the same certificate and bundle identifier as the
//  installed copy, then hand it to the installer.
//

import Foundation
import CoreData
import Combine
import OSLog
import UIKit

@MainActor
final class AutoUpdater: ObservableObject {
	static let shared = AutoUpdater()

	nonisolated static let autoUpdateOnOpenKey = "Feather.autoUpdateOnOpen"

	enum Phase: Equatable {
		case queued
		case downloading(Double)
		case importing
		case signing
		case failed(String)

		var isActive: Bool {
			if case .failed = self { return false }
			return true
		}
	}

	/// Work items: update from a source, or sign + install what is in the library.
	private enum Job {
		case update(AppUpdate)
		case install(uuid: String, name: String)
		
		var uuid: String {
			switch self {
			case .update(let update): update.localUUID
			case .install(let uuid, _): uuid
			}
		}
	}
	
	/// Phase of each local app (keyed by the local UUID) being updated.
	@Published private(set) var phases: [String: Phase] = [:]
	/// Signed app waiting to be installed; presented at the app root.
	@Published var installItem: AnyApp?

	private var _queue: [Job] = []
	private var _isProcessing = false
	private var _installQueue: [AnyApp] = []
	private var _pendingNotificationUUID: String?

	private init() {}

	var isBusy: Bool {
		_isProcessing || !_queue.isEmpty
	}

	// MARK: Public API

	func update(_ update: AppUpdate) {
		guard phases[update.localUUID]?.isActive != true else { return }
		phases[update.localUUID] = .queued
		_queue.append(.update(update))
		_processNext()
	}
	
	/// AltServer-style install: always signs automatically (same certificate as the
	/// app, or the default one, and the real application identifier) and installs.
	/// Works the same for imported and signed apps.
	func signAndInstall(_ app: AppInfoPresentable) {
		guard let uuid = app.uuid, phases[uuid]?.isActive != true else { return }
		phases[uuid] = .queued
		_queue.append(.install(uuid: uuid, name: app.name ?? ""))
		_processNext()
	}

	/// Updates every app with a pending update (one per app, the signed copy
	/// when there is one). Apps that already failed are skipped here so an
	/// automatic run does not retry them in a loop; the user retries with "Update".
	func updateAll() {
		for item in UpdateManager.shared.actionableUpdates {
			if case .failed = phases[item.localUUID] { continue }
			update(item)
		}
	}

	func updateFromNotification(localUUID: String) async {
		if let pending = UpdateManager.shared.updates[localUUID] {
			update(pending)
			return
		}

		// Cold start from a notification: updates are not loaded yet.
		_pendingNotificationUUID = localUUID
		await UpdateManager.shared.checkForUpdatesUsingStorage(notify: false)
		_consumePendingNotification()
	}

	/// Called after every update check.
	func didFinishCheck() {
		_consumePendingNotification()

		// Background refresh only notifies; the update itself runs with Feather open.
		if
			UserDefaults.standard.bool(forKey: Self.autoUpdateOnOpenKey),
			UIApplication.shared.applicationState == .active
		{
			updateAll()
		}
	}

	func installDismissed() {
		_presentNextInstall()
	}

	func clearFailure(for uuid: String) {
		if case .failed = phases[uuid] {
			phases[uuid] = nil
		}
	}

	// MARK: Queue

	private func _consumePendingNotification() {
		guard
			let uuid = _pendingNotificationUUID,
			let pending = UpdateManager.shared.updates[uuid]
		else {
			return
		}
		_pendingNotificationUUID = nil
		update(pending)
	}

	private func _processNext() {
		guard !_isProcessing, !_queue.isEmpty else { return }
		_isProcessing = true
		let next = _queue.removeFirst()

		Task { @MainActor in
			do {
				switch next {
				case .update(let update): try await _run(update)
				case .install(let uuid, _): try await _runInstall(uuid: uuid)
				}
				phases[next.uuid] = nil
			} catch {
				Logger.misc.error("Auto sign/update failed for \(next.uuid): \(error.localizedDescription)")
				phases[next.uuid] = .failed(error.localizedDescription)
				let title: String
				let subject: String
				switch next {
				case .update(let update):
					title = .localized("Update Failed")
					subject = "\(update.appName) \(update.remoteVersion)"
				case .install(_, let name):
					title = .localized("Install")
					subject = name
				}
				UIAlertController.showAlertWithOk(
					title: title,
					message: "\(subject)\n\(error.localizedDescription)"
				)
			}
			_isProcessing = false
			_processNext()
		}
	}

	// MARK: Pipeline

	private func _run(_ update: AppUpdate) async throws {
		guard let localApp = _app(uuid: update.localUUID) else {
			throw AutoUpdateError.localAppMissing
		}
		
		// Resolve everything we need from the current copy before deleting it.
		let installedIdentifier = localApp.identifier
		let certificate = try _validCertificate(for: localApp)
		
		// 1. Download
		phases[update.localUUID] = .downloading(0)
		let ipa = try await _download(update.downloadURL) { [weak self] progress in
			self?.phases[update.localUUID] = .downloading(progress)
		}
		defer { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }
		
		// 2. Import (keeps the source metadata so future checks keep working)
		phases[update.localUUID] = .importing
		let importer = AppFileHandler(file: ipa, sourceProvenance: update.sourceProvenance)
		do {
			try await importer.copy()
			try await importer.extract()
			try await importer.move()
			try await importer.addToDatabase()
			try? await importer.clean()
		} catch {
			try? await importer.clean()
			throw error
		}
		
		guard let imported = _app(uuid: importer.uuid) else {
			throw AutoUpdateError.importFailed
		}
		
		// 3. Sign automatically, like AltServer: same certificate and the same
		//    bundle identifier, so iOS updates the installed app in place.
		phases[update.localUUID] = .signing
		let signed: AppInfoPresentable
		do {
			signed = try await _sign(imported, identifier: installedIdentifier, certificate: certificate)
		} catch {
			Storage.shared.deleteApp(for: imported)
			throw error
		}
		
		// The intermediate copy and the old one are replaced by the signed update.
		Storage.shared.deleteApp(for: imported)
		Storage.shared.deleteApp(for: localApp)
		_finish(update)
		
		// 4. Install
		_enqueueInstall(signed)
	}
	
	private func _runInstall(uuid: String) async throws {
		guard let app = _app(uuid: uuid) else {
			throw AutoUpdateError.localAppMissing
		}
		
		let certificate = try _validCertificate(for: app)
		
		phases[uuid] = .signing
		let signed = try await _sign(app, identifier: app.identifier, certificate: certificate)
		
		// A re-signed copy replaces the previous signed one; imported apps are
		// kept unless the user chose to delete them after signing.
		if app.isSigned || OptionsManager.shared.options.post_deleteAppAfterSigned {
			Storage.shared.deleteApp(for: app)
		}
		
		_enqueueInstall(signed)
	}
	
	/// Signs with the given certificate and the real application identifier
	/// (TEAMID.bundle, not the profile wildcard) and returns the new signed copy.
	private func _sign(
		_ app: AppInfoPresentable,
		identifier: String?,
		certificate: CertificatePair
	) async throws -> AppInfoPresentable {
		var options = OptionsManager.shared.options
		options.signingOption = .default
		options.appIdentifier = identifier
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false
		// iOS only upgrades in place when the application-identifier matches.
		options.mergeEntitlements = true
		options.appEntitlementsFile = nil
		
		let signer = SigningHandler(app: app, options: options)
		signer.appCertificate = certificate
		do {
			try await signer.copy()
			try await signer.modify()
			try? await signer.clean()
		} catch {
			try? await signer.clean()
			// modify() may have stored the new copy before reporting the error.
			if let broken = _app(uuid: signer.uuid) {
				Storage.shared.deleteApp(for: broken)
			}
			throw error
		}
		
		guard let signed = _app(uuid: signer.uuid) else {
			throw AutoUpdateError.signFailed
		}
		return signed
	}
	
	private func _validCertificate(for app: AppInfoPresentable) throws -> CertificatePair {
		guard let certificate = _certificate(for: app) else {
			throw AutoUpdateError.noCertificate
		}
		if certificate.revoked {
			throw AutoUpdateError.certificateRevoked
		}
		if let expiration = certificate.expiration, expiration < Date() {
			throw AutoUpdateError.certificateExpired
		}
		return certificate
	}
	
	private func _finish(_ update: AppUpdate) {
		UpdateManager.shared.removeUpdate(localUUID: update.localUUID)
		UpdateNotifier.shared.clearDelivered(for: update.bundleIdentifier)
	}

	private func _enqueueInstall(_ app: AppInfoPresentable) {
		let isSelf = app.identifier == Bundle.main.bundleIdentifier
		let usesServer = UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 0

		// Feather cannot reinstall itself through the local server.
		guard !(isSelf && usesServer) else { return }

		_installQueue.append(AnyApp(base: app))
		if installItem == nil {
			_presentNextInstall()
		}
	}

	private func _presentNextInstall() {
		guard installItem == nil, !_installQueue.isEmpty else { return }
		// Small delay so a previous sheet finishes dismissing.
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 450_000_000)
			guard installItem == nil, !_installQueue.isEmpty else { return }
			installItem = _installQueue.removeFirst()
		}
	}

	// MARK: Helpers

	private func _download(
		_ url: URL,
		progress: @escaping @MainActor (Double) -> Void
	) async throws -> URL {
		let (tempURL, response) = try await _ProgressDownloader(progress: progress).download(url)

		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			throw AutoUpdateError.badResponse(http.statusCode)
		}

		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("FeatherAutoUpdate_\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectoryIfNeeded(at: dir)

		let name = response.suggestedFilename ?? url.lastPathComponent
		let fileName = name.lowercased().hasSuffix(".ipa") || name.lowercased().hasSuffix(".tipa") ? name : "\(name).ipa"
		let destination = dir.appendingPathComponent(fileName)
		try FileManager.default.moveItem(at: tempURL, to: destination)
		return destination
	}

	private func _certificate(for app: AppInfoPresentable) -> CertificatePair? {
		if let cert = Storage.shared.getCertificate(from: app) {
			return cert
		}
		// Fall back to the certificate selected in Settings (the default one).
		let index = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		return Storage.shared.getCertificate(for: index)
	}

	private func _app(uuid: String) -> AppInfoPresentable? {
		let context = Storage.shared.context

		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		signedRequest.fetchLimit = 1
		if let signed = try? context.fetch(signedRequest).first {
			return signed
		}

		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		importedRequest.fetchLimit = 1
		return try? context.fetch(importedRequest).first
	}
}

// MARK: - Errors
enum AutoUpdateError: LocalizedError {
	case localAppMissing
	case noCertificate
	case importFailed
	case signFailed
	case certificateRevoked
	case certificateExpired
	case badResponse(Int)

	var errorDescription: String? {
		switch self {
		case .localAppMissing: .localized("The app to update was not found in the library.")
		case .noCertificate: .localized("No certificate available to sign the update.")
		case .importFailed: .localized("The downloaded update could not be imported.")
		case .signFailed: .localized("The update could not be signed.")
		case .certificateRevoked: .localized("The certificate used by this app is revoked.")
		case .certificateExpired: .localized("The certificate used by this app has expired.")
		case .badResponse(let code): "HTTP \(code)"
		}
	}
}

// MARK: - Download with progress
private final class _ProgressDownloader: NSObject, URLSessionDownloadDelegate {
	private let _progress: @MainActor (Double) -> Void
	private var _continuation: CheckedContinuation<(URL, URLResponse), Error>?
	private var _session: URLSession?

	init(progress: @escaping @MainActor (Double) -> Void) {
		self._progress = progress
	}

	func download(_ url: URL) async throws -> (URL, URLResponse) {
		try await withCheckedThrowingContinuation { continuation in
			self._continuation = continuation
			let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
			self._session = session
			session.downloadTask(with: url).resume()
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard totalBytesExpectedToWrite > 0 else { return }
		let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
		let report = _progress
		Task { @MainActor in report(value) }
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		// The system deletes `location` when this method returns: move it first.
		let kept = FileManager.default.temporaryDirectory
			.appendingPathComponent("FeatherAutoUpdate_\(UUID().uuidString).download")
		do {
			try FileManager.default.moveItem(at: location, to: kept)
			if let response = downloadTask.response {
				_continuation?.resume(returning: (kept, response))
			} else {
				_continuation?.resume(throwing: URLError(.badServerResponse))
			}
		} catch {
			_continuation?.resume(throwing: error)
		}
		_continuation = nil
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if let error {
			_continuation?.resume(throwing: error)
			_continuation = nil
		}
		session.finishTasksAndInvalidate()
		_session = nil
	}
}

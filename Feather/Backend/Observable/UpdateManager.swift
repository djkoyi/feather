//
//  UpdateManager.swift
//  Feather
//
//  Created by Dominic on 24.05.2026.
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceProvenance: SourceAppProvenance
	/// The local copy is a signed app (the one that is installed on the device).
	let isSigned: Bool
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	nonisolated static let autoCheckEnabledKey = "Feather.autoCheckUpdates"
	
	/// Automatic checks (on open and in the background). On by default.
	nonisolated static var isAutoCheckEnabled: Bool {
		UserDefaults.standard.object(forKey: autoCheckEnabledKey) as? Bool ?? true
	}
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	/// Bundle identifiers that have a signed copy in the library.
	private var _signedBundleIDs: Set<String> = []
	
	private let _dataService = NBFetchService()
	
	private init() {}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable],
		notify: Bool = true
	) async {
		guard !isChecking else { return }
		
		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}
		
		let repositories = await _fetchRepositories(from: sources)
		_signedBundleIDs = Set(localApps.filter(\.isSigned).compactMap(\.identifier))
		updates = _findUpdates(repositories: repositories, localApps: localApps)
		_signedBundleIDs.formUnion(updates.values.filter(\.isSigned).map(\.bundleIdentifier))

		if notify {
			await UpdateNotifier.shared.notify(about: actionableUpdates)
		} else {
			UpdateNotifier.shared.refreshBadge(count: distinctUpdateCount)
		}
		AutoUpdater.shared.didFinishCheck()
	}

	/// Same check without a view: reads sources and apps straight from Core Data.
	/// Used at launch, when returning to the foreground and from background refresh.
	func checkForUpdatesUsingStorage(notify: Bool = true) async {
		let context = Storage.shared.context
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		let signed = (try? context.fetch(signedRequest)) ?? []
		let imported = (try? context.fetch(importedRequest)) ?? []
		let localApps = signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }

		await checkForUpdates(
			sources: Storage.shared.getSources(),
			localApps: localApps,
			notify: notify
		)
	}

	/// Called after an app was updated so its badge/notification disappear right away.
	func removeUpdate(localUUID: String) {
		updates[localUUID] = nil
		UpdateNotifier.shared.refreshBadge(count: distinctUpdateCount)
	}

	/// One update per app, the way AltStore shows them. When an app has a signed
	/// copy (the one installed on the device) only signed copies count; imported
	/// copies of that app are just cached IPAs and are not announced or auto-updated.
	var actionableUpdates: [AppUpdate] {
		var byBundle: [String: AppUpdate] = [:]
		for update in updates.values.sorted(by: { $0.localUUID < $1.localUUID }) {
			if update.isSigned {
				if byBundle[update.bundleIdentifier]?.isSigned != true {
					byBundle[update.bundleIdentifier] = update
				}
			} else if
				!_signedBundleIDs.contains(update.bundleIdentifier),
				byBundle[update.bundleIdentifier] == nil
			{
				byBundle[update.bundleIdentifier] = update
			}
		}
		return byBundle.values.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
	}
	
	/// Number of apps with an actionable update (badge and "Update All").
	var distinctUpdateCount: Int {
		actionableUpdates.count
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		
		for source in sources {
			guard let url = source.sourceURL else {
				continue
			}
			
			guard let repository = await _fetchRepository(from: url) else {
				continue
			}
			
			repositories.append((source, repository))
		}
		
		return repositories
	}
	
	private func _fetchRepository(from url: URL) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			_dataService.fetch(from: url) { (result: RepositoryDataHandler) in
				switch result {
				case .success(let repository):
					continuation.resume(returning: repository)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
		}
	}
	
	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		localApps: [AppInfoPresentable]
	) -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		let metadataCandidates = localApps.compactMap { app -> SourceMetadataCandidate? in
			guard
				let uuid = app.uuid,
				let metadata = metadataByUUID[uuid]
			else {
				return nil
			}
			return SourceMetadataCandidate(appUUID: uuid, app: app, metadata: metadata)
		}
		
		for localApp in localApps {
			guard let localUUID = localApp.uuid else {
				continue
			}
			
			let sourceAppIdentifier: String
			let sourceAppVersion: String?
			let storedSourceURL: URL?
			if let directMetadata = metadataByUUID[localUUID] {
				guard
					let metadataSourceAppIdentifier = directMetadata.sourceAppIdentifier,
					let metadataSourceURL = directMetadata.sourceRepositoryURL
				else {
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = directMetadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
			} else if let fallback = _fallbackMetadataCandidate(
				for: localApp,
				localUUID: localUUID,
				candidates: metadataCandidates
			) {
				guard
					let metadataSourceAppIdentifier = fallback.metadata.sourceAppIdentifier,
					let metadataSourceURL = fallback.metadata.sourceRepositoryURL
				else {
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = fallback.metadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
				Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				)
			} else if
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			{
				sourceAppIdentifier = AutoUpdater.originalIdentifier(for: localIdentifier)
				sourceAppVersion = localApp.version
				storedSourceURL = localSourceURL
			} else if let localIdentifier = localApp.identifier {
				// Imported from a URL or Files: no source is linked. Like AltStore,
				// look the bundle identifier up in every source (the original one
				// when the app was installed under a custom identifier).
				sourceAppIdentifier = AutoUpdater.originalIdentifier(for: localIdentifier)
				sourceAppVersion = localApp.version
				storedSourceURL = nil
			} else {
				continue
			}
			
			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else {
					continue
				}
				
				if let storedSourceURL {
					guard _matchesStoredRepository(storedSourceURL: storedSourceURL, sourceURL: sourceURL) else {
						continue
					}
				}
				
				guard let remoteApp = repository.apps.first(where: { $0.id == sourceAppIdentifier }) else {
					continue
				}
				
				guard let remoteVersion = remoteApp.currentVersion, !remoteVersion.isEmpty else {
					continue
				}
				
				// Only newer versions count; an older build in the source is not an update.
				guard Self.isVersion(remoteVersion, newerThan: sourceAppVersion ?? localApp.version) else {
					continue
				}
				
				guard let downloadURL = remoteApp.currentDownloadUrl else {
					continue
				}
				
				guard let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				) else {
					continue
				}
				
				foundUpdates[localUUID] = AppUpdate(
					id: localUUID,
					localUUID: localUUID,
					localVersion: sourceAppVersion ?? localApp.version,
					remoteVersion: remoteVersion,
					appName: remoteApp.currentName,
					bundleIdentifier: sourceAppIdentifier,
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					sourceProvenance: provenance,
					isSigned: localApp.isSigned
				)
				break
			}
		}
		
		return foundUpdates
	}
	
	/// Numeric, component-wise comparison for plain versions ("2.10" > "2.9",
	/// "1.0" == "1.0.0"). When either side has letters (betas, nightly hashes)
	/// there is no reliable order, so any different version counts as an update.
	nonisolated static func isVersion(_ remote: String, newerThan local: String?) -> Bool {
		let remote = remote.trimmingCharacters(in: .whitespaces)
		guard let local = local?.trimmingCharacters(in: .whitespaces), !local.isEmpty else { return true }
		guard remote != local else { return false }
		
		let isPlain: (String) -> Bool = { version in
			!version.isEmpty && version.allSatisfy { $0.isNumber || $0 == "." }
		}
		guard isPlain(remote), isPlain(local) else {
			return true
		}
		
		let remoteParts = remote.split(separator: ".").map { $0.trimmingPrefixZeros }
		let localParts = local.split(separator: ".").map { $0.trimmingPrefixZeros }
		for index in 0..<max(remoteParts.count, localParts.count) {
			let r = index < remoteParts.count ? remoteParts[index] : "0"
			let l = index < localParts.count ? localParts[index] : "0"
			// Compare as digit strings: no overflow for very long build numbers.
			if r.count != l.count { return r.count > l.count }
			if r != l { return r > l }
		}
		return false
	}
	
	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
	}
	
	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		
		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
	}
	
	private func _fallbackMetadataCandidate(
		for localApp: AppInfoPresentable,
		localUUID: String,
		candidates: [SourceMetadataCandidate]
	) -> SourceMetadataCandidate? {
		guard
			localApp.isSigned,
			let localIdentifier = localApp.identifier,
			let localVersion = localApp.version
		else {
			return nil
		}
		
		return candidates.first {
			$0.appUUID != localUUID &&
			!$0.app.isSigned &&
			$0.app.identifier == localIdentifier &&
			$0.app.version == localVersion
		}
	}
}

private struct SourceMetadataCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let metadata: AppSourceMetadata
}

private extension Substring {
	/// "007" -> "7", "0" -> "0"
	var trimmingPrefixZeros: String {
		let trimmed = drop(while: { $0 == "0" })
		return trimmed.isEmpty ? "0" : String(trimmed)
	}
}

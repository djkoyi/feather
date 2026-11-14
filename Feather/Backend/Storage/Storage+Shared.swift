//
//  Storage+Shared.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData

// MARK: - Class extension: Apps (Shared)
extension Storage {
	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
			? FileManager.default.signed(uuid)
			: FileManager.default.unsigned(uuid)
	}
	
	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}
	
	func deleteApp(for app: AppInfoPresentable) {
		// Already deleted (e.g. replaced by a newer copy): nothing left to do.
		if let object = app as? NSManagedObject, object.isDeleted || object.managedObjectContext == nil {
			return
		}
		do {
			if let url = getUuidDirectory(for: app) {
				try? FileManager.default.removeItem(at: url)
			}
			deleteSourceMetadata(for: app.uuid)
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
			saveContext()
		}
	}
	
	/// Keeps only the newest copy of an app in its section: when a new version is
	/// imported (or signed), the previous ones with the same bundle identifier go.
	/// Signed copies with different identifiers are different installed apps.
	func removeOlderCopies(identifier: String?, keeping uuid: String, signed: Bool) {
		guard let identifier, !identifier.isEmpty else { return }
		for old in _copies(identifier: identifier, signed: signed) where old.uuid != uuid {
			deleteApp(for: old)
		}
	}
	
	/// Cleans duplicates left by older versions of Feather: per section and
	/// bundle identifier, only the most recent copy stays.
	func removeOlderDuplicates() {
		for signed in [true, false] {
			var seen = Set<String>()
			for app in _copies(identifier: nil, signed: signed) {
				guard let identifier = app.identifier, !identifier.isEmpty else { continue }
				if !seen.insert(identifier).inserted {
					deleteApp(for: app)
				}
			}
		}
	}
	
	/// Copies of a section, newest first (all of them when `identifier` is nil).
	private func _copies(identifier: String?, signed: Bool) -> [AppInfoPresentable] {
		let predicate = identifier.map { NSPredicate(format: "identifier == %@", $0) }
		let sort = [NSSortDescriptor(key: "date", ascending: false)]
		if signed {
			let request: NSFetchRequest<Signed> = Signed.fetchRequest()
			request.predicate = predicate
			request.sortDescriptors = sort
			return (try? context.fetch(request)) ?? []
		}
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = predicate
		request.sortDescriptors = sort
		return (try? context.fetch(request)) ?? []
	}
	
	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}
}

// MARK: - Helpers
struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
	
	var id: String {
		base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var source: URL? { get }
	var isSigned: Bool { get }
	
}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}

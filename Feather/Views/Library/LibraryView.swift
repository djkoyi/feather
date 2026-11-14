//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var updateManager = UpdateManager.shared
	@StateObject private var _installedMonitor = InstalledAppsMonitor.shared
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting
	@State private var _updateCheckRotation = 0.0
	@State private var _isUpdateCheckCompleteVisible = false
	
	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive
	
	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all
	
	
	@Namespace private var _namespace
	
	// horror
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty ||
				(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}
	
	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}
	
	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}
	
	/// Apps with a pending update go first, in their own section.
	private var _updateApps: [AnyApp] {
		var apps: [AppInfoPresentable] = []
		if _selectedScope == .all || _selectedScope == .signed {
			apps += _filteredSignedApps.filter { updateManager.update(for: $0) != nil }
		}
		if _selectedScope == .all || _selectedScope == .imported {
			apps += _filteredImportedApps.filter { updateManager.update(for: $0) != nil }
		}
		return apps.map { AnyApp(base: $0) }
	}
	
	private var _upToDateSignedApps: [Signed] {
		_filteredSignedApps.filter { updateManager.update(for: $0) == nil }
	}
	
	/// Signed and on the device.
	private var _installedApps: [Signed] {
		_upToDateSignedApps.filter { _installedMonitor.isInstalled($0.identifier) }
	}
	
	/// Signed but not on the device (removed, or never installed).
	private var _signedOnlyApps: [Signed] {
		_upToDateSignedApps.filter { !_installedMonitor.isInstalled($0.identifier) }
	}
	
	private var _upToDateImportedApps: [Imported] {
		_filteredImportedApps.filter { updateManager.update(for: $0) == nil }
	}
	
	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Library")) {
			NBListAdaptable {
				let updateApps = _updateApps
				if !updateApps.isEmpty {
					Section {
						ForEach(updateApps) { item in
							_cell(for: item.base)
						}
					} header: {
						_updatesHeader(count: updateApps.count)
					}
				}
				
				if
					!_installedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					NBSection(
						.localized("Installed"),
						secondary: _installedApps.count.description,
						systemName: "iphone"
					) {
						ForEach(_installedApps, id: \.uuid) { app in
							_cell(for: app)
						}
					}
				}
				
				if
					!_signedOnlyApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					NBSection(
						.localized("Signed"),
						secondary: _signedOnlyApps.count.description,
						systemName: "signature"
					) {
						ForEach(_signedOnlyApps, id: \.uuid) { app in
							_cell(for: app)
						}
					}
				}
				
				if
					!_upToDateImportedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .imported
				{
					NBSection(
						.localized("Downloaded"),
						secondary: _upToDateImportedApps.count.description,
						systemName: "arrow.down.circle"
					) {
						ForEach(_upToDateImportedApps, id: \.uuid) { app in
							_cell(for: app)
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.compatSearchScopes($_selectedScope) {
				ForEach(Scope.allCases, id: \.displayName) { scope in
					Text(scope.displayName).tag(scope)
				}
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay {
				if
					_filteredSignedApps.isEmpty,
					_filteredImportedApps.isEmpty
				{
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Apps"), systemImage: "questionmark.app.fill")
						} description: {
							Text(.localized("Get started by importing your first IPA file."))
						} actions: {
							Menu {
								_importActions()
							} label: {
								NBButton(.localized("Import"), style: .text)
							}
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					EditButton()
				}
				
				if _editMode.isEditing {
					NBToolbarButton(
						.localized("Delete"),
						systemImage: "trash",
						isDisabled: _selectedAppUUIDs.isEmpty
					) {
						_bulkDeleteSelectedApps()
					}
				} else {
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							Task {
								await _checkForUpdates()
							}
						} label: {
							Image(systemName: _isUpdateCheckCompleteVisible ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
								.rotationEffect(.degrees(_updateCheckRotation))
								.animation(
									updateManager.isChecking
										? .linear(duration: 0.8).repeatForever(autoreverses: false)
										: .default,
									value: _updateCheckRotation
								)
						}
						.disabled(updateManager.isChecking)
						.accessibilityLabel(.localized("Check for Updates"))
					}
					
					NBToolbarMenu(
						systemImage: "plus",
						style: .icon,
						placement: .topBarTrailing
					) {
						_importActions()
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						
						for url in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							try? downloadManager.handlePachageFile(url: url, dl: dl)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				if let latest = _signedApps.first {
					_selectedInstallAppPresenting = AnyApp(base: latest)
				}
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
			.onChange(of: updateManager.isChecking) { isChecking in
				_handleUpdateCheckStateChange(isChecking)
			}
			.onAppear {
				_installedMonitor.seedIfNeeded(signedIdentifiers: _signedApps.compactMap(\.identifier))
			}
			.task {
				guard UpdateManager.isAutoCheckEnabled, !updateManager.isChecking else { return }
				let last = updateManager.lastCheckedDate ?? .distantPast
				guard Date().timeIntervalSince(last) > 30 else { return }
				await _checkForUpdates()
			}
		}
	}
}

// MARK: - Extension: View
extension LibraryView {
	private func _cell(for app: AppInfoPresentable) -> some View {
		LibraryCellView(
			app: app,
			isInstalled: app.isSigned && _installedMonitor.isInstalled(app.identifier),
			selectedInfoAppPresenting: $_selectedInfoAppPresenting,
			selectedSigningAppPresenting: $_selectedSigningAppPresenting,
			selectedInstallAppPresenting: $_selectedInstallAppPresenting,
			selectedAppUUIDs: $_selectedAppUUIDs
		)
		.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
	}
	
	private func _updatesHeader(count: Int) -> some View {
		HStack(alignment: .center, spacing: 6) {
			Image(systemName: "arrow.down.circle.fill")
				.font(.system(size: 12))
				.foregroundStyle(Color.accentColor)
				.offset(y: -2)
			Text(.localized("Updates"))
				.font(.title2)
				.fontWeight(.bold)
				.foregroundStyle(.primary)
			Spacer()
			if !_editMode.isEditing {
				Button {
					AutoUpdater.shared.updateAll()
				} label: {
					Text(verbatim: .localized("Update All") + " (\(count))")
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 12)
						.padding(.vertical, 5)
						.background(Capsule().fill(Color.accentColor))
				}
				.buttonStyle(.borderless)
				.textCase(nil)
				.accessibilityLabel(.localized("Update All"))
			}
		}
		.textCase(nil)
		.offset(y: 2)
	}
	
	@ViewBuilder
	private func _importActions() -> some View {
		Button(.localized("Import from Files"), systemImage: "folder") {
			_isImportingPresenting = true
		}
		Button(.localized("Import from URL"), systemImage: "globe") {
			_isDownloadingPresenting = true
		}
	}
}

// MARK: - Extension: Bulk Delete
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}
		
		for app in selectedApps {
			Storage.shared.deleteApp(for: app)
		}
		
		_selectedAppUUIDs.removeAll()
		
		// _editMode = .inactive
	}
	
	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		
		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _filteredSignedApps)
		}
		
		if _selectedScope == .all || _selectedScope == .imported {
			allApps.append(contentsOf: _filteredImportedApps)
		}
		
		return allApps
	}
	
	private func _checkForUpdates() async {
		let localApps = _signedApps.map { $0 as AppInfoPresentable } + _importedApps.map { $0 as AppInfoPresentable }
		await updateManager.checkForUpdates(
			sources: Array(_sources),
			localApps: localApps
		)
	}
	
	private func _handleUpdateCheckStateChange(_ isChecking: Bool) {
		if isChecking {
			_isUpdateCheckCompleteVisible = false
			_updateCheckRotation = 0
			withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
				_updateCheckRotation = 360
			}
		} else {
			withAnimation(.none) {
				_updateCheckRotation = 0
			}
			
			_isUpdateCheckCompleteVisible = true
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 900_000_000)
				if !updateManager.isChecking {
					_isUpdateCheckCompleteVisible = false
				}
			}
		}
	}
}

// MARK: - Extension: View (Sort)
extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported
		
		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .imported: return .localized("Downloaded")
			}
		}
	}
}

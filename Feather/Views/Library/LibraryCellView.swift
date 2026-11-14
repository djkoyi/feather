//
//  LibraryAppIconView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var updateManager = UpdateManager.shared
	@ObservedObject private var autoUpdater = AutoUpdater.shared
	@State private var _isCustomIdentifierPresented = false
	@State private var _customIdentifier = ""

	var certInfo: Date.ExpirationInfo? {
		Storage.shared.getCertificate(from: app)?.expiration?.expirationInfo()
	}
	
	var certRevoked: Bool {
		Storage.shared.getCertificate(from: app)?.revoked == true
	}
	
	var app: AppInfoPresentable
	/// Signed copy that is on the device: its main action is Open, not Install.
	var isInstalled: Bool = false
	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>
	
	// MARK: Selections
	private var _isSelected: Bool {
		guard let uuid = app.uuid else { return false }
		return selectedAppUUIDs.contains(uuid)
	}
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}
	
	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active
		
		HStack(spacing: 14) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			_appIcon(for: app)
			
			_details
				.frame(maxWidth: .infinity, alignment: .leading)
			
			if !isEditing {
				_buttonActions(for: app)
			}
		}
		.padding(isRegular ? 12 : 0)
		.padding(.vertical, isRegular ? 0 : 6)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(_isSelected && isEditing ? Color.accentColor.opacity(0.1) : Color(.quaternarySystemFill))
				: nil
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				_actions(for: app)
			}
		}
		// Modified apps often ship with the official app's bundle identifier;
		// this installs them under another one so both can coexist.
		.alert(.localized("Install with Another Identifier"), isPresented: $_isCustomIdentifierPresented) {
			TextField(.localized("Bundle Identifier"), text: $_customIdentifier)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Install")) {
				let identifier = _customIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
				guard Self._isValidBundleIdentifier(identifier) else {
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: .localized("Invalid bundle identifier. Use letters, numbers, hyphens and dots, for example com.example.app.")
					)
					return
				}
				autoUpdater.signAndInstall(app, identifier: identifier)
			}
		} message: {
			Text(verbatim: app.identifier ?? "")
		}
	}
	
	/// Name, version (current -> new when there is an update), identifier and
	/// how long the certificate of the signed copy is still valid.
	private var _details: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(app.name ?? .localized("Unknown"))
				.font(.headline)
				.lineLimit(1)
			
			HStack(spacing: 4) {
				Text(verbatim: app.version ?? "?")
					.foregroundStyle(.secondary)
				if let update = updateManager.update(for: app) {
					Image(systemName: "arrow.right")
						.font(.caption2.weight(.bold))
						.foregroundStyle(.secondary)
					Text(verbatim: update.remoteVersion)
						.fontWeight(.semibold)
						.foregroundStyle(Color.accentColor)
				}
			}
			.font(.subheadline)
			.lineLimit(1)
			.monospacedDigit()
			
			if let identifier = app.identifier {
				Text(verbatim: identifier)
					.font(.caption)
					.foregroundStyle(.tertiary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			
			if app.isSigned {
				_certificateStatus
			}
		}
	}
	
	@ViewBuilder
	private var _certificateStatus: some View {
		if certRevoked {
			Label(.localized("Revoked"), systemImage: "xmark.seal.fill")
				.font(.caption2.weight(.semibold))
				.foregroundStyle(.red)
		} else if let certInfo {
			Label(certInfo.formatted, systemImage: certInfo.icon)
				.font(.caption2.weight(.semibold))
				.foregroundStyle(certInfo.color)
		}
	}
}


// MARK: - Extension: View
extension LibraryCellView {
	private func _appIcon(for app: AppInfoPresentable) -> some View {
		FRAppIconView(app: app, size: 57)
			.overlay(alignment: .topTrailing) {
				if updateManager.update(for: app) != nil {
					Image(systemName: "arrow.down.circle.fill")
						.font(.system(size: 18, weight: .semibold))
						.symbolRenderingMode(.palette)
						.foregroundStyle(.white, Color.accentColor)
						.background(
							Circle()
								.fill(Color(.systemBackground))
								.frame(width: 20, height: 20)
						)
						.offset(x: 5, y: -5)
						.accessibilityLabel(.localized("Update Available"))
				}
			}
	}
	
	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteApp(for: app)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
		if let update = updateManager.update(for: app) {
			Button(.localized("Update"), systemImage: "arrow.down.circle") {
				_startUpdate(update)
			}
		}
		
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					_open(id)
				}
			}
			// Always signs automatically before installing (AltServer-style).
			Button(
				isInstalled ? .localized("Reinstall") : .localized("Install"),
				systemImage: isInstalled ? "arrow.clockwise" : "square.and.arrow.down"
			) {
				autoUpdater.signAndInstall(app)
			}
			_installWithIdentifierButton(for: app)
			Button(.localized("Re-sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export"), systemImage: "square.and.arrow.up") {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			}
		} else {
			// Imported apps are signed automatically and installed in one step.
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				autoUpdater.signAndInstall(app)
			}
			_installWithIdentifierButton(for: app)
			Button(.localized("Sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}
	
	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		Group {
			if let uuid = app.uuid, let phase = autoUpdater.phases[uuid], phase.isActive {
				_phaseIndicator(phase)
			} else if let update = updateManager.update(for: app) {
				// One tap: download, sign with the same certificate and install.
				Button {
					_startUpdate(update)
				} label: {
					_pill(.localized("Update"), prominent: true)
				}
			} else if isInstalled, let identifier = app.identifier {
				Button {
					_open(identifier)
				} label: {
					_pill(.localized("Open"), prominent: false)
				}
			} else {
				// One tap, like AltStore: sign automatically and install,
				// whether the app is imported or already signed.
				Button {
					autoUpdater.signAndInstall(app)
				} label: {
					_pill(.localized("Install"), prominent: false)
				}
			}
		}
		.buttonStyle(.borderless)
	}
	
	private func _pill(_ title: String, prominent: Bool) -> some View {
		Text(title)
			.font(.subheadline.weight(.bold))
			.lineLimit(1)
			.foregroundStyle(prominent ? Color.white : Color.accentColor)
			.padding(.horizontal, 14)
			.padding(.vertical, 6)
			.background(
				Capsule().fill(prominent ? Color.accentColor : Color.accentColor.opacity(0.14))
			)
	}
	
	/// Download ring with percentage, or a small spinner while preparing/signing.
	@ViewBuilder
	private func _phaseIndicator(_ phase: AutoUpdater.Phase) -> some View {
		if case .downloading(let progress) = phase {
			ZStack {
				Circle()
					.stroke(Color.accentColor.opacity(0.18), lineWidth: 3)
				Circle()
					.trim(from: 0, to: max(0.02, progress))
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(.linear(duration: 0.2), value: progress)
				Text(verbatim: "\(Int(progress * 100))")
					.font(.system(size: 10, weight: .bold))
					.monospacedDigit()
					.foregroundStyle(Color.accentColor)
			}
			.frame(width: 34, height: 34)
			.accessibilityLabel(_title(for: phase))
		} else {
			HStack(spacing: 6) {
				ProgressView()
					.controlSize(.small)
				Text(_title(for: phase))
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
	}
	
	@ViewBuilder
	private func _installWithIdentifierButton(for app: AppInfoPresentable) -> some View {
		Button(.localized("Install with Another Identifier"), systemImage: "character.cursor.ibeam") {
			_customIdentifier = app.identifier ?? ""
			_isCustomIdentifierPresented = true
		}
	}
	
	private static func _isValidBundleIdentifier(_ identifier: String) -> Bool {
		identifier.range(
			of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$",
			options: .regularExpression
		) != nil
	}
	
	/// If the app is gone from the device it moves back to Signed (Install).
	private func _open(_ identifier: String) {
		let title = app.name ?? .localized("Open")
		InstalledAppsMonitor.shared.open(identifier) {
			UIAlertController.showAlertWithOk(
				title: title,
				message: .localized("This app is not installed on this device. Tap Install to install it again.")
			)
		}
	}
	
	private func _startUpdate(_ update: AppUpdate) {
		autoUpdater.update(update)
	}
	
	private func _title(for phase: AutoUpdater.Phase) -> String {
		switch phase {
		case .queued: .localized("Waiting")
		case .downloading(let progress): "\(Int(progress * 100))%"
		case .importing: .localized("Preparing")
		case .signing: .localized("Signing")
		case .failed: .localized("Update")
		}
	}
}

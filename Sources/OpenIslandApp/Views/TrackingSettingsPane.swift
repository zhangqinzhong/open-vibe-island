import AppKit
import OpenIslandCore
import SwiftUI

struct TrackingSettingsPane: View {
    var model: AppModel

    @State private var apps: [CustomTrackedApp] = []
    @State private var editingApp: CustomTrackedApp?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                appList

                hint
            }
            .padding(24)
        }
        .navigationTitle("Tracking")
        .onAppear { apps = model.customTrackedApps }
        .sheet(item: $editingApp) { app in
            EditTrackedAppSheet(app: app) { confirmed in
                if let confirmed {
                    model.addCustomTrackedApp(confirmed)
                    apps = model.customTrackedApps
                }
                editingApp = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom App Tracking")
                .font(.headline)
            Text("Add any macOS app whose built-in terminal runs AI agents. Open Island will recognise sessions launched from these apps and show the app name in the session badge.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - App list

    private var appList: some View {
        VStack(spacing: 0) {
            if apps.isEmpty {
                emptyState
            } else {
                ForEach(apps) { app in
                    appRow(app)
                    if app.id != apps.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }

            Divider()

            addButton
        }
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No custom apps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 28)
            Spacer()
        }
    }

    private func appRow(_ app: CustomTrackedApp) -> some View {
        HStack(spacing: 12) {
            appIcon(for: app)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(app.terminalAppKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.06), in: Capsule())

            Button {
                model.removeCustomTrackedApp(bundleID: app.bundleID)
                apps = model.customTrackedApps
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var addButton: some View {
        Button {
            pickApp()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.blue)
                Text("Add Application…")
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hint

    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("How it works", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Open Island reads the TERM_PROGRAM and __CFBundleIdentifier environment variables that the app injects into its shell. If your app sets TERM_PROGRAM to a custom value, use that value as the Badge Name.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - App picker

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.message = "Select the app whose built-in terminal runs AI agents."
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        // Pause the process-monitoring poller before runModal(). The poller uses
        // Task.detached + DispatchGroup.wait() internally; when its detached task
        // completes it tries to resume on @MainActor, but runModal()'s nested
        // AppKit event loop prevents Swift Concurrency from servicing that
        // resumption, causing a permanent deadlock. Pausing the poller for the
        // duration of the modal dialog avoids this entirely.
        model.pauseMonitoring()
        defer { model.resumeMonitoring() }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let appName = bundle?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent

        // Setting editingApp to non-nil triggers .sheet(item:) automatically.
        editingApp = CustomTrackedApp(
            bundleID: bundleID,
            appName: appName,
            terminalAppKey: appName
        )
    }

    // MARK: - App icon helper

    @ViewBuilder
    private func appIcon(for app: CustomTrackedApp) -> some View {
        if let icon = NSWorkspace.shared.icon(forFile: appPath(for: app)) as NSImage? {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }

    private func appPath(for app: CustomTrackedApp) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path ?? ""
    }
}

// MARK: - Edit sheet

private struct EditTrackedAppSheet: View {
    let app: CustomTrackedApp
    let onDone: (CustomTrackedApp?) -> Void

    @State private var badgeName: String

    init(app: CustomTrackedApp, onDone: @escaping (CustomTrackedApp?) -> Void) {
        self.app = app
        self.onDone = onDone
        _badgeName = State(initialValue: app.terminalAppKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                appIconView
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.headline)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Badge Name")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("The label shown in the island session card. Usually the app name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Superset", text: $badgeName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    guard !badgeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onDone(CustomTrackedApp(
                        bundleID: app.bundleID,
                        appName: app.appName,
                        terminalAppKey: badgeName.trimmingCharacters(in: .whitespaces)
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(badgeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var appIconView: some View {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path ?? ""
        if !path.isEmpty {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        }
    }
}

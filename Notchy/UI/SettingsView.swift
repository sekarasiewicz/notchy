import Combine
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var manager: MenuBarManager
    @StateObject private var spacing = MenuBarSpacing.shared
    @State private var confirmSpacing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = Accessibility.isTrusted
    @State private var screenRecordingGranted = ItemImageCapture.hasPermission()

    private let permissionsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Fold the hidden section when icons run out of room", isOn: $manager.autoCollapse)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Show real icon glyphs in the panel", isOn: $manager.captureGlyphs)
                    Text("Uses screen capture. macOS shows its purple recording indicator whenever glyphs are refreshed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Icon spacing") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tighter")
                        Slider(value: Binding(get: { Double(spacing.offset) }, set: { spacing.offset = Int($0.rounded()) }), in: -12...12, step: 1)
                        Text("Wider")
                    }
                    HStack {
                        Text(spacing.offset == 0 ? "System default" : "\(spacing.offset > 0 ? "+" : "")\(spacing.offset) pt per icon")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if spacing.isApplying {
                            ProgressView().controlSize(.small)
                        }
                        Button("Apply…") { confirmSpacing = true }
                            .disabled(!spacing.hasUnappliedChange || spacing.isApplying)
                    }
                    Text("Icons read this setting only when their app starts, so applying quits and relaunches every app that has a menu bar icon.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = spacing.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                .confirmationDialog("Relaunch apps with menu bar icons?", isPresented: $confirmSpacing) {
                    Button("Apply and relaunch") {
                        Task { await spacing.apply(items: manager.items) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(relaunchList())
                }
            }

            Section("Permissions") {
                permissionRow(
                    "Accessibility",
                    detail: "Required. Finds which app owns each icon and moves icons on your behalf.",
                    granted: accessibilityGranted
                ) {
                    Accessibility.requestTrust()
                    openPrivacyPane("Privacy_Accessibility")
                }
                permissionRow(
                    "Screen Recording",
                    detail: "Optional. Shows the real icon glyphs in the panel instead of app icons.",
                    granted: screenRecordingGranted
                ) {
                    ItemImageCapture.requestPermission()
                    openPrivacyPane("Privacy_ScreenCapture")
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                Link("Source on GitHub", destination: URL(string: "https://github.com/sekarasiewicz/notchy")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(permissionsTimer) { _ in
            accessibilityGranted = Accessibility.isTrusted
            screenRecordingGranted = ItemImageCapture.hasPermission()
        }
    }

    private func relaunchList() -> String {
        let names = Set(manager.items.compactMap(\.appName)).subtracting(["Notchy", "Control Centre", "Control Center"]).sorted()
        return names.isEmpty ? "No apps found." : names.joined(separator: ", ")
    }

    @ViewBuilder
    private func permissionRow(_ title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? Color.green : Color.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…", action: request)
            }
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

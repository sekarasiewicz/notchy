import Combine
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var manager: MenuBarManager
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

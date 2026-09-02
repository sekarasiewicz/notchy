import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var manager: MenuBarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notchy").font(.headline)
                Spacer()
                Toggle("Collapse", isOn: Binding(
                    get: { manager.isHiddenSectionCollapsed },
                    set: { manager.setHiddenSectionCollapsed($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if !manager.lostItems.isEmpty {
                Label("\(manager.lostItems.count) item(s) have no room on screen", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("HIDDEN")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if manager.hiddenSectionItems.isEmpty {
                Text("Nothing left of the divider. ⌘-drag icons past the ‹ to hide them.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 4)], spacing: 4) {
                    ForEach(manager.hiddenSectionItems) { item in
                        Button { manager.reveal(item) } label: {
                            Group {
                                if let image = manager.hiddenImages[item.key] {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                } else if let icon = manager.fallbackIcon(for: item) {
                                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(3)
                                } else {
                                    Text(String(item.displayName.prefix(2))).font(.caption).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 36, height: 24)
                            .padding(2)
                            // Menu bar glyphs are white on a dark bar; keep that ground.
                            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(item.displayName)
                    }
                }
            }

            Toggle("Fold hidden section when icons run out of room", isOn: $manager.autoCollapse)
                .font(.caption)
                .controlSize(.mini)

            if !ItemImageCapture.hasPermission() {
                HStack(spacing: 6) {
                    Text("Showing app icons. Allow Screen Recording to see the real glyphs.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { ItemImageCapture.requestPermission() }
                        .controlSize(.mini)
                }
            }

            section("Visible", manager.visibleSectionItems)

            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [MenuBarItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.isOnScreen ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(item.displayName).font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(Int(item.frame.minX))–\(Int(item.frame.maxX))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

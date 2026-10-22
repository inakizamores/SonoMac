import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MenuView: View {
    @Environment(SonosSystem.self) private var sonos
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                CapsuleSlider(
                    value: Binding(
                        get: { sonos.masterVolume },
                        set: { sonos.setMasterVolume($0) }
                    ),
                    icon: CapsuleSlider.speakerIcon(Int(sonos.masterVolume.rounded()),
                                                    muted: sonos.allMuted),
                    label: "All Rooms",
                    onEditingChanged: { sonos.masterEditing($0) },
                    onIconTap: { sonos.toggleMuteAll() }
                )
                .disabled(sonos.groups.isEmpty)
                .opacity(sonos.groups.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Divider()
                .padding(.horizontal, 10)
            scrollArea
        }
        .frame(width: 320)
        .animation(.panel, value: sonos.groups.isEmpty)
        .modifier(PanelSizer())
        .onAppear { sonos.menuOpened() }
        .onDisappear { sonos.menuClosed() }
    }

    /// Rooms and the Sound section scroll together under one ceiling.
    /// Previously only the room list was capped, and the Sound section sat
    /// outside it — a few expanded rooms plus a full home-theater EQ could
    /// grow the panel taller than the screen.
    private static let maxScrollHeight: CGFloat = 560

    /// Only wraps in a ScrollView once the content genuinely overflows: a
    /// ScrollView that is always present costs nothing visually but doesn't
    /// render offscreen, which breaks README screenshots — hence also the
    /// `isScreenshotting` opt-out.
    private var needsScroll: Bool {
        !isScreenshotting && contentHeight > Self.maxScrollHeight
    }

    @ViewBuilder
    private var scrollArea: some View {
        if needsScroll {
            ScrollView { panelContent }
                .frame(height: Self.maxScrollHeight)
                .scrollBounceBehavior(.basedOnSize)
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            content
            if !sonos.groups.isEmpty {
                Divider()
                    .padding(.horizontal, 10)
                SoundSection()
            }
        }
        // Measured either way, so the switch can't oscillate: inside the
        // ScrollView this still reports the content's own height, which stays
        // above the ceiling that put it there.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self,
                                       value: geo.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sonos")
                .font(.system(.body, weight: .semibold))
            // With rooms already listed, the empty state's spinner never
            // shows, so Rescan Network looked like it did nothing at all.
            if sonos.isScanning && !sonos.groups.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Spacer()
            settingsMenu
        }
        .animation(.panel, value: sonos.isScanning)
    }

    @Environment(\.isScreenshotting) private var isScreenshotting

    @ViewBuilder
    private var settingsMenu: some View {
        if isScreenshotting {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        } else {
            realSettingsMenu
        }
    }

    private var realSettingsMenu: some View {
        Menu {
            // Two independent conditions. Rooms can be combined when there is
            // more than one group; they can be pulled apart when any group
            // holds more than one speaker. Sharing a single `groups.count > 1`
            // guard got both cases backwards — it offered "Separate All Rooms"
            // to an already-separate system, then hid it as soon as anything
            // was grouped, since grouping *reduces* the group count.
            let canGroup = sonos.groups.count > 1
            let canSeparate = sonos.groups.contains { $0.members.count > 1 }
            // Shown for any multi-speaker system rather than only when levels
            // actually differ: we can't tell a collapsed room is uneven
            // without polling its players, and hiding the item when it's
            // needed would be the worse failure.
            let canEvenOut = sonos.groups.reduce(0) { $0 + $1.members.count } > 1
            if canGroup {
                Button("Group All Rooms") { sonos.groupAll() }
            }
            if canSeparate {
                Button("Separate All Rooms") { sonos.separateAll() }
            }
            if canEvenOut {
                Button("Even Out All Volumes") { sonos.evenOutAll() }
            }
            if canGroup || canSeparate || canEvenOut {
                Divider()
            }
            Toggle("Start at Login", isOn: Binding(
                get: { sonos.launchAtLogin },
                set: { sonos.setLaunchAtLogin($0) }
            ))
            Button("Rescan Network") { sonos.rescan() }
            Divider()
            Button("Quit SonoMac") { sonos.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if sonos.groups.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            groupList
        }
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            // Keyed on the stable arrangement, not the group ID Sonos
            // renumbers, so a confirmed regroup reuses the row it drew
            // optimistically instead of tearing it down and rebuilding it.
            ForEach(sonos.groups, id: \.key) { group in
                GroupCard(group: group)
                if group.id != sonos.groups.last?.id {
                    Divider().padding(.horizontal, 10)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if sonos.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for Sonos…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "hifispeaker")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No Sonos Speakers Found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Scan Again") { sonos.rescan() }
                    .controlSize(.small)
            }
        }
    }
}

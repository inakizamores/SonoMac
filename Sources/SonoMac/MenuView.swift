import SwiftUI

struct MenuView: View {
    @Environment(SonosSystem.self) private var sonos

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
            content
            if !sonos.groups.isEmpty {
                Divider()
                    .padding(.horizontal, 10)
                SoundSection()
            }
        }
        .frame(width: 320)
        .onAppear { sonos.menuOpened() }
        .onDisappear { sonos.menuClosed() }
    }

    private var header: some View {
        HStack {
            Text("Sonos")
                .font(.system(.body, weight: .semibold))
            Spacer()
            settingsMenu
        }
    }

    private var settingsMenu: some View {
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
        } else if sonos.groups.count > 4 {
            ScrollView {
                groupList
            }
            .frame(maxHeight: 440)
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

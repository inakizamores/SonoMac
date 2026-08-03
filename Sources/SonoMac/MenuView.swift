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
                    icon: sonos.allMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
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
        }
        .frame(width: 320)
        .onAppear { sonos.menuOpened() }
        .onDisappear { sonos.menuClosed() }
    }

    private var header: some View {
        HStack {
            Text("Sonos")
                .font(.system(.body, weight: .bold))
            Spacer()
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            if sonos.groups.count > 1 {
                Button("Group All Rooms") { sonos.groupAll() }
                Button("Separate All Rooms") { sonos.separateAll() }
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
            ForEach(sonos.groups) { group in
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

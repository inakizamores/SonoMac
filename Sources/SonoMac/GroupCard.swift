import SwiftUI

struct GroupCard: View {
    @Environment(SonosSystem.self) private var sonos
    let group: SonosGroup
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.displayName)
                        .lineLimit(1)
                    if !group.nowPlaying.isEmpty {
                        Text(group.nowPlaying)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                controls
            }
            HStack(spacing: 8) {
                CapsuleSlider(
                    value: Binding(
                        get: { Double(group.volume) },
                        set: { sonos.setGroupVolume(group.id, Int($0.rounded())) }
                    ),
                    icon: group.muted ? "speaker.slash.fill" : "speaker.fill",
                    onEditingChanged: { sonos.groupEditing(group.id, $0) },
                    onIconTap: { sonos.toggleMute(group.id) }
                )
                if group.members.count > 1 { expandButton }
            }
            if expanded && group.members.count > 1 { memberList }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { groupMenu }
        .onChange(of: expanded) { _, isOn in
            sonos.setExpanded(group.id, isOn)
        }
    }

    // MARK: Header controls

    private var controls: some View {
        HStack(spacing: 2) {
            if sonos.htCapable(group.coordinatorUUID) {
                iconButton(group.isTVInput ? "tv.fill" : "tv",
                           active: group.isTVInput,
                           help: group.isTVInput ? "Playing TV audio" : "Switch to TV audio") {
                    sonos.toggleTV(group.id)
                }
            }
            iconButton("backward.fill", help: "Previous") {
                sonos.previous(group.id)
            }
            iconButton(playing ? "pause.fill" : "play.fill",
                       primary: true,
                       help: playing ? "Pause" : "Play") {
                sonos.playPause(group.id)
            }
            iconButton("forward.fill", help: "Next") {
                sonos.next(group.id)
            }
        }
    }

    private var playing: Bool {
        group.transportState == .playing || group.transportState == .transitioning
    }

    private func iconButton(_ symbol: String,
                            active: Bool = false, primary: Bool = false,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(primary ? .medium : .small)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                                 : primary ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(.secondary))
                .frame(width: 23, height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var expandButton: some View {
        Button {
            withAnimation { expanded.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .rotationEffect(expanded ? .degrees(180) : .zero)
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show speakers")
    }

    // MARK: Per-speaker rows

    private var memberList: some View {
        VStack(spacing: 6) {
            ForEach(group.members) { member in
                HStack(spacing: 8) {
                    Text(member.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 80, alignment: .leading)
                    CapsuleSlider(
                        value: Binding(
                            get: { Double(member.volume) },
                            set: { sonos.setMemberVolume(group.id, member.uuid, Int($0.rounded())) }
                        ),
                        height: 16
                    )
                    Button { sonos.removeFromGroup(member) } label: {
                        Image(systemName: "minus.circle")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from group")
                }
            }
            if group.volumeSpread >= 3 {
                Button { sonos.evenOut(group.id) } label: {
                    Label("Even Out Volumes", systemImage: "equal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .help("Set every speaker to the group average")
            }
        }
        .padding(.top, 2)
    }

    // MARK: Context menu

    @ViewBuilder
    private var groupMenu: some View {
        let others = sonos.groups.filter { $0.id != group.id }
        if !others.isEmpty {
            Menu("Group With") {
                ForEach(others) { other in
                    Button(other.displayName) { sonos.merge(group.id, into: other.id) }
                }
            }
        }
        if group.members.count > 1 {
            Button("Separate Speakers") { sonos.separate(group.id) }
            Button("Even Out Volumes") { sonos.evenOut(group.id) }
        }
    }
}

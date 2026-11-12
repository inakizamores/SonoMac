import SwiftUI

struct GroupCard: View {
    @Environment(SonosSystem.self) private var sonos
    let group: SonosGroup
    @State private var expanded: Bool
    /// The speaker rows are fading out before the card closes.
    @State private var closing = false

    init(group: SonosGroup, initiallyExpanded: Bool = false) {
        self.group = group
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.displayName)
                        .lineLimit(1)
                    if !group.online {
                        Text("Not responding")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .transition(.panelRow)
                    } else if !group.nowPlaying.isEmpty {
                        Text(group.nowPlaying)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.panelRow)
                    }
                    if showFormat, let format = group.audioFormat {
                        HStack(spacing: 4) {
                            if let symbol = format.symbol {
                                Image(systemName: symbol)
                                    .imageScale(.small)
                                    .accessibilityHidden(true)
                            }
                            Text(format.text)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .transition(.panelRow)
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
                    icon: CapsuleSlider.speakerIcon(group.volume, muted: group.muted),
                    label: group.displayName,
                    onEditingChanged: { sonos.groupEditing(group.id, $0) },
                    onIconTap: { sonos.toggleMute(group.id) }
                )
                if group.members.count > 1 { expandButton }
            }
            if expanded && group.members.count > 1 {
                memberList
                    .opacity(closing ? 0 : 1)
                    .transition(.panelRow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // A room we can't reach gets dimmed and inert rather than keeping a
        // live-looking card whose controls quietly do nothing.
        .opacity(group.online ? 1 : 0.45)
        .disabled(!group.online)
        .conditionalContextMenu(hasGroupMenu) { groupMenu }
        .onChange(of: expanded) { _, isOn in
            sonos.setExpanded(group.key, isOn)
        }
        .animation(.panel, value: layoutKey)
    }

    /// Its own row, so the track line keeps the full width.
    private var showFormat: Bool {
        sonos.showAudioFormat && group.online
            && !group.nowPlaying.isEmpty && group.audioFormat != nil
    }

    /// Rows that come and go on their own — the now-playing line, the TV
    /// button once the model is known, and Even Out once the speakers drift
    /// apart. None of these arrive through a button press, so without this
    /// they resize the panel with no transaction to animate them.
    private var layoutKey: String {
        "\(group.nowPlaying.isEmpty)\(showFormat)\(showEvenOut)\(group.members.count)"
            + "\(sonos.htCapable(group.coordinatorUUID))\(group.online)"
    }

    private var showEvenOut: Bool {
        group.volumeSpread >= 3
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

    /// Opening grows the panel and then fades the rows in; closing fades
    /// them out and then shrinks it, so nothing is drawn while the edge
    /// passes over it.
    private func toggleExpanded() {
        guard expanded else {
            closing = false
            withAnimation(.panel) { expanded = true }
            return
        }
        guard !closing else { return }
        withAnimation(.easeIn(duration: 0.09)) { closing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            guard closing else { return }
            withAnimation(.panel) { expanded = false }
            closing = false
        }
    }

    private var expandButton: some View {
        Button {
            toggleExpanded()
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
                        height: 16,
                        label: member.name,
                        onEditingChanged: { sonos.memberEditing(group.id, member.uuid, $0) }
                    )
                    if member.uuid != group.coordinatorUUID {
                        Button { sonos.removeFromGroup(member) } label: {
                            Image(systemName: "minus.circle")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from group")
                    } else {
                        // Keeps the sliders aligned with the rows that do
                        // have a button.
                        Color.clear.frame(width: 13, height: 1)
                    }
                }
            }
            if showEvenOut {
                Button { sonos.evenOut(group.id) } label: {
                    Label("Even Out Volumes", systemImage: "equal.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .help("Set every speaker to the group average")
                .transition(.panelRow)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Context menu

    /// Right-clicking a single standalone room used to open an empty popup:
    /// nothing to group with, and no speakers to separate or level.
    private var hasGroupMenu: Bool {
        sonos.groups.count > 1 || group.members.count > 1
    }

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

private extension View {
    @ViewBuilder
    func conditionalContextMenu<M: View>(_ enabled: Bool,
                                         @ViewBuilder _ menu: () -> M) -> some View {
        if enabled { self.contextMenu(menuItems: menu) } else { self }
    }
}

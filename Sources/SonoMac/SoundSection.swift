import SwiftUI

/// Collapsible sound settings at the foot of the panel. Sonos scopes EQ to a
/// room rather than a group, so the section carries its own room picker
/// instead of following the group list above it.
struct SoundSection: View {
    @Environment(SonosSystem.self) private var sonos
    @Environment(\.isScreenshotting) private var isScreenshotting

    /// Shared column widths, so labels, sliders and readouts line up straight
    /// down the panel no matter which section a row belongs to.
    private let labelWidth: CGFloat = 74
    private let valueWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if sonos.soundExpanded {
                Group {
                    if let settings = sonos.sound {
                        controls(settings)
                    } else {
                        loading
                    }
                }
                .transition(.panelRow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.panel, value: layoutKey)
    }

    /// Everything that changes which rows exist — and nothing that changes a
    /// value. Animating on the settings themselves would put the bass slider
    /// behind the panel curve and make it feel like it was dragging its feet.
    private var layoutKey: String {
        guard let s = sonos.sound else { return "loading" }
        return "\(sonos.soundExpanded)\(s.outputFixed)\(s.hasSub)\(s.subEnabled)"
            + "\(s.hasSurrounds)\(s.surroundEnabled)\(s.isHomeTheater)"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                sonos.setSoundExpanded(!sonos.soundExpanded)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(sonos.soundExpanded ? .zero : .degrees(-90))
                    Text("Sound")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sonos.soundExpanded ? "Hide sound settings" : "Show sound settings")

            Spacer(minLength: 8)

            if sonos.soundExpanded, sonos.soundRooms.count > 1 {
                roomPicker
            }
        }
    }

    @ViewBuilder
    private var roomPicker: some View {
        if isScreenshotting {
            HStack(spacing: 4) {
                Text(sonos.currentSoundRoom?.name ?? "—")
                    .font(.subheadline)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        } else {
            realRoomPicker
        }
    }

    private var realRoomPicker: some View {
        Menu {
            ForEach(sonos.soundRooms) { room in
                Button(room.name) { sonos.selectSoundRoom(room.uuid) }
            }
        } label: {
            Text(sonos.currentSoundRoom?.name ?? "—")
                .font(.subheadline)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var loading: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Reading settings…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ s: SoundSettings) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if s.outputFixed {
                Text("This room has a fixed line-out — tone controls are handled by your amplifier.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                section("Tone") {
                    stepSlider("Bass", value: s.bass, range: -10...10) { sonos.setBass($0) }
                    stepSlider("Treble", value: s.treble, range: -10...10) { sonos.setTreble($0) }
                    switchRow("Loudness", isOn: s.loudness) { sonos.setLoudness($0) }
                }
            }

            if s.hasSub {
                section("Sub", isOn: s.subEnabled, set: { sonos.setSubEnabled($0) }) {
                    if s.subEnabled {
                        stepSlider("Level", value: s.subGain, range: -15...15) {
                            sonos.setSubGain($0)
                        }
                        .transition(.panelRow)
                    }
                }
            }

            if s.hasSurrounds {
                section("Surround", isOn: s.surroundEnabled,
                        set: { sonos.setSurroundEnabled($0) }) {
                    if s.surroundEnabled {
                        Group {
                            stepSlider("TV", value: s.surroundLevel, range: -15...15) {
                                sonos.setSurroundLevel($0)
                            }
                            stepSlider("Music", value: s.musicSurroundLevel, range: -15...15) {
                                sonos.setMusicSurroundLevel($0)
                            }
                            musicPlayback(s)
                        }
                        .transition(.panelRow)
                    }
                }
            }

            if s.isHomeTheater {
                section("Home Theater") {
                    switchRow("Night Sound", isOn: s.nightMode) { sonos.setNightMode($0) }
                    switchRow("Speech", isOn: s.dialogLevel) { sonos.setDialogLevel($0) }
                }
            }
        }
    }

    /// A titled run of rows. Sections that can be switched off carry the
    /// switch in their own header rather than spending a whole row on a
    /// control named after the section it heads.
    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        isOn: Bool? = nil,
                                        set: ((Bool) -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let isOn, let set {
                    if isScreenshotting {
                        fakeSwitch(isOn)
                    } else {
                        Toggle("", isOn: Binding(get: { isOn }, set: set))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
            }
            content()
        }
    }

    // MARK: Rows

    /// Bipolar settings read as a centred native slider rather than a capsule
    /// fill — the capsule means "level from zero", which is the wrong idea for
    /// a value that runs negative.
    private func stepSlider(_ label: String, value: Int, range: ClosedRange<Int>,
                            set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if isScreenshotting {
                fakeSlider(fraction: CGFloat(value - range.lowerBound)
                           / CGFloat(range.upperBound - range.lowerBound))
            } else {
                Slider(value: Binding(get: { Double(value) },
                                      set: { set(Int($0.rounded())) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .controlSize(.small)
            }
            Text(value > 0 ? "+\(value)" : "\(value)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    /// Ambient vs Full is a choice between two named modes, not a level, so it
    /// reads as a segmented control. Padded on the right by the readout column
    /// so it ends flush with the sliders above it.
    private func musicPlayback(_ s: SoundSettings) -> some View {
        HStack(spacing: 8) {
            Text("Playback")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if isScreenshotting {
                fakeSegmented(["Ambient", "Full"], selected: s.musicFull ? 1 : 0)
            } else {
                Picker("", selection: Binding(get: { s.musicFull },
                                              set: { sonos.setMusicFull($0) })) {
                    Text("Ambient").tag(false)
                    Text("Full").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            Color.clear.frame(width: valueWidth, height: 1)
        }
    }

    private func switchRow(_ label: String, isOn: Bool,
                           set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isScreenshotting {
                fakeSwitch(isOn)
            } else {
                Toggle("", isOn: Binding(get: { isOn }, set: set))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }

    // MARK: Screenshot stand-ins (AppKit controls can't render offscreen)

    private func fakeSlider(fraction: CGFloat) -> some View {
        GeometryReader { geo in
            let knob: CGFloat = 14
            let x = fraction * (geo.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 16)
    }

    private func fakeSwitch(_ isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .frame(width: 26, height: 15)
            Circle()
                .fill(.white)
                .frame(width: 13, height: 13)
                .padding(.horizontal, 1)
                .shadow(color: .black.opacity(0.3), radius: 1)
        }
    }

    private func fakeSegmented(_ options: [String], selected: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                Text(label)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(i == selected ? AnyShapeStyle(Color(white: 0.42))
                                                : AnyShapeStyle(.clear))
                    )
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary))
    }
}

import SwiftUI
import AppKit

/// Renders the real UI to PNGs for the README when the app is launched
/// with `--render-screenshots <dir>`. Not reachable in normal use.
@MainActor
enum ScreenshotRenderer {
    static func runIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-screenshots"),
              CommandLine.arguments.count > i + 1 else { return }
        renderAll(to: CommandLine.arguments[i + 1])
        exit(0)
    }

    private static func sampleSystem() -> SonosSystem {
        let sys = SonosSystem()
        var living = SonosGroup(id: "g1", coordinatorUUID: "u1", members: [
            SonosSpeaker(uuid: "u1", name: "Living Room", ip: "0", volume: 62),
            SonosSpeaker(uuid: "u2", name: "Kitchen", ip: "0", volume: 55),
            SonosSpeaker(uuid: "u3", name: "Dining", ip: "0", volume: 68),
        ])
        living.volume = 62
        living.transportState = .playing
        living.nowPlaying = "Nothing You Can't Do — Max Light Quartet"

        var bedroom = SonosGroup(id: "g2", coordinatorUUID: "u4", members: [
            SonosSpeaker(uuid: "u4", name: "Bedroom", ip: "0", volume: 35),
        ])
        bedroom.volume = 35
        bedroom.transportState = .paused

        var tvRoom = SonosGroup(id: "g3", coordinatorUUID: "u5", members: [
            SonosSpeaker(uuid: "u5", name: "TV Room", ip: "0", volume: 45),
        ])
        tvRoom.volume = 45
        tvRoom.transportState = .playing
        tvRoom.isTVInput = true
        tvRoom.nowPlaying = "TV Audio"

        sys.models["u5"] = "Sonos Arc"
        sys.groups = [living, bedroom, tvRoom]
        sys.masterVolume = 47
        return sys
    }

    private static func renderAll(to dir: String) {
        let sys = sampleSystem()
        render(MenuView().environment(sys), name: "screenshot-panel", dir: dir)
        let expanded = GroupCard(group: sys.groups[0], initiallyExpanded: true)
            .environment(sys)
            .frame(width: 320)
            .padding(.vertical, 4)
        render(expanded, name: "screenshot-speakers", dir: dir)
    }

    private static func render<V: View>(_ view: V, name: String, dir: String) {
        let content = view
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.13))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(32)
            .environment(\.colorScheme, .dark)
            .environment(\.isScreenshotting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("rendered \(name).png")
    }
}

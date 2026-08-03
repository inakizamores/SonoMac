import SwiftUI

@main
struct SonoMacApp: App {
    @State private var sonos = SonosSystem()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(sonos)
        } label: {
            Image(systemName: "hifispeaker")
        }
        .menuBarExtraStyle(.window)
    }
}

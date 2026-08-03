import Foundation

enum TransportState: String, Sendable {
    case playing, paused, stopped, transitioning

    init(upnp: String) {
        switch upnp {
        case "PLAYING": self = .playing
        case "TRANSITIONING": self = .transitioning
        case "PAUSED_PLAYBACK": self = .paused
        default: self = .stopped
        }
    }
}

struct SonosSpeaker: Identifiable, Hashable, Sendable {
    let uuid: String        // RINCON_xxxxxxxxxxxx01400
    let name: String        // zone name, e.g. "Living Room"
    let ip: String
    var volume: Int = 0
    var muted: Bool = false

    var id: String { uuid }
}

struct SonosGroup: Identifiable, Hashable, Sendable {
    let id: String          // group ID, e.g. RINCON_xxx:123
    let coordinatorUUID: String
    var members: [SonosSpeaker]   // coordinator first
    var volume: Int = 0
    var muted: Bool = false
    var transportState: TransportState = .stopped
    var nowPlaying: String = ""
    var isTVInput: Bool = false

    var coordinator: SonosSpeaker {
        members.first(where: { $0.uuid == coordinatorUUID }) ?? members[0]
    }

    var displayName: String {
        members.count > 1 ? "\(coordinator.name) + \(members.count - 1)" : coordinator.name
    }

    var volumeSpread: Int {
        let vols = members.map(\.volume)
        guard let lo = vols.min(), let hi = vols.max() else { return 0 }
        return hi - lo
    }
}

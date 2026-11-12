import Foundation

enum TransportState: String, Sendable, Codable {
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

struct SonosSpeaker: Identifiable, Hashable, Sendable, Codable {
    let uuid: String        // RINCON_xxxxxxxxxxxx01400
    let name: String        // zone name, e.g. "Living Room"
    let ip: String
    var volume: Int = 0
    var muted: Bool = false
    /// A Sub bonded to this room, per the topology's channel map. Deliberately
    /// outside CodingKeys: bonding can change while the panel is closed, so
    /// this is re-read from the speakers rather than restored from cache.
    var hasSub: Bool = false
    /// Rear surrounds bonded to this room, same source and same reasoning.
    var hasSurrounds: Bool = false

    var id: String { uuid }

    private enum CodingKeys: String, CodingKey {
        case uuid, name, ip, volume, muted
    }
}

struct SonosGroup: Identifiable, Hashable, Sendable, Codable {
    let id: String          // group ID, e.g. RINCON_xxx:123
    let coordinatorUUID: String
    var members: [SonosSpeaker]   // coordinator first
    var volume: Int = 0
    var muted: Bool = false
    var transportState: TransportState = .stopped
    var nowPlaying: String = ""
    var isTVInput: Bool = false
    /// What's coming in: "Dolby Atmos", "Lossless 16/44.1", "Dolby Digital
    /// Plus 5.1". Not persisted — it describes this moment's stream, and a
    /// restored one would vouch for a track that may have long changed.
    var audioFormat: String = ""
    /// Whether the coordinator answered the last poll. Not persisted — a
    /// restored "unreachable" would be a claim about a system we haven't
    /// spoken to yet.
    var online: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id, coordinatorUUID, members, volume, muted
        case transportState, nowPlaying, isTVInput
    }

    /// Identity that survives Sonos renumbering group IDs, which it does on
    /// every grouping change. Views keyed on `id` were torn down and rebuilt
    /// each time a group was confirmed, losing expansion state and flashing;
    /// keyed on this, an optimistic group and its confirmed self are the
    /// same row.
    var key: String {
        members.map(\.uuid).sorted().joined(separator: ",")
    }

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

/// What the TV is sending a home-theater speaker, decoded from the
/// `HTAudioIn` code in DeviceProperties.GetZoneInfo — the same reading the
/// Sonos app shows under TV audio.
///
/// The code is a bitfield: the top byte is the main channel count, the next
/// nibble the LFE count, the low byte the codec. Decoding the fields rather
/// than matching a table of whole codes means layouts nobody has written down
/// yet (DTS 7.1, say) still read correctly.
enum TVAudioFormat {
    static func label(_ code: Int) -> String? {
        let codec = code & 0xFF
        let main = (code >> 24) & 0xFF
        let lfe = (code >> 20) & 0xF
        let layout = main > 0 ? " \(main).\(lfe)" : ""
        switch codec {
        case 59, 61, 63: return "Dolby Atmos"   // over DD+, TrueHD, MAT
        case 18: return "Dolby Digital 5.1"      // older firmware's code
        case 7, 56, 57: return "Dolby Digital" + layout
        case 58: return "Dolby Digital Plus" + layout
        case 60: return "Dolby TrueHD" + layout
        case 62: return "Dolby Multichannel PCM" + layout
        case 65: return "DTS" + layout
        case 2: return main > 2 ? "Multichannel PCM" + layout : "Stereo PCM"
        case 22: return "No audio"
        default: return nil                      // nothing connected / unknown
        }
    }
}

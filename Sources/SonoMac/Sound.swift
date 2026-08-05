import Foundation

/// Per-room sound settings, as exposed by RenderingControl. Sonos keeps these
/// per room rather than per group, so they are fetched for one room at a time.
struct SoundSettings: Sendable, Equatable {
    var bass = 0                 // -10...10
    var treble = 0               // -10...10
    var loudness = false
    var subEnabled = true
    var subGain = 0              // -15...15
    var nightMode = false
    var dialogLevel = false

    var surroundEnabled = true
    var surroundLevel = 0        // -15...15, surrounds during TV
    var musicSurroundLevel = 0   // -15...15, surrounds during music
    var musicFull = false        // SurroundMode: false = Ambient, true = Full

    // Capabilities. Decided from the topology and the model name, never from
    // whether a query happens to answer — see fetchSound.
    var outputFixed = false      // fixed line-out: the amp owns the tone controls
    var hasSub = false
    var hasSurrounds = false
    var isHomeTheater = false
}

extension SonosSystem {

    // MARK: - Room selection

    /// Every visible zone, flattened out of the groups: EQ belongs to a room,
    /// not to whatever group it happens to be playing in right now.
    var soundRooms: [SonosSpeaker] {
        groups.flatMap(\.members)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var currentSoundRoom: SonosSpeaker? {
        soundRooms.first(where: { $0.uuid == soundRoom }) ?? soundRooms.first
    }

    func setSoundExpanded(_ on: Bool) {
        soundExpanded = on
        UserDefaults.standard.set(on, forKey: "soundExpanded")
        if on { Task { await loadSound() } }
    }

    func selectSoundRoom(_ uuid: String) {
        guard uuid != currentSoundRoom?.uuid else { return }
        soundRoom = uuid
        UserDefaults.standard.set(uuid, forKey: "soundRoom")
        // Deliberately keep the current controls on screen while the new room
        // loads. Blanking to a spinner and back reflows the panel twice and
        // flashes, for a fetch that takes about a tenth of a second.
        Task { await loadSound() }
    }

    /// Fetched on demand rather than polled — these settings only change from
    /// this panel or the Sonos app, and the panel is built to stay quiet.
    func loadSound() async {
        guard soundExpanded, let room = currentSoundRoom else { return }
        let s = await Self.fetchSound(ip: room.ip,
                                      hasSub: room.hasSub,
                                      hasSurrounds: room.hasSurrounds,
                                      homeTheater: htCapable(room.uuid))
        // The picker may have moved on while the request was in flight.
        guard currentSoundRoom?.uuid == room.uuid else { return }
        sound = s
    }

    // MARK: - Writes

    func setBass(_ v: Int) {
        writeSound(\.bass, max(-10, min(10, v))) { ip, val in
            _ = try? await SOAP.call(.renderingControl, action: "SetBass",
                                     args: [("InstanceID", "0"), ("DesiredBass", "\(val)")], host: ip)
        }
    }

    func setTreble(_ v: Int) {
        writeSound(\.treble, max(-10, min(10, v))) { ip, val in
            _ = try? await SOAP.call(.renderingControl, action: "SetTreble",
                                     args: [("InstanceID", "0"), ("DesiredTreble", "\(val)")], host: ip)
        }
    }

    func setSubGain(_ v: Int) {
        writeSound(\.subGain, max(-15, min(15, v))) { ip, val in
            await Self.setEQ(ip, "SubGain", val)
        }
    }

    func setLoudness(_ on: Bool) {
        writeSound(\.loudness, on) { ip, val in
            _ = try? await SOAP.call(.renderingControl, action: "SetLoudness",
                                     args: [("InstanceID", "0"), ("Channel", "Master"),
                                            ("DesiredLoudness", val ? "1" : "0")], host: ip)
        }
    }

    func setSubEnabled(_ on: Bool) {
        writeSound(\.subEnabled, on) { ip, val in await Self.setEQ(ip, "SubEnable", val ? 1 : 0) }
    }

    func setNightMode(_ on: Bool) {
        writeSound(\.nightMode, on) { ip, val in await Self.setEQ(ip, "NightMode", val ? 1 : 0) }
    }

    func setDialogLevel(_ on: Bool) {
        writeSound(\.dialogLevel, on) { ip, val in await Self.setEQ(ip, "DialogLevel", val ? 1 : 0) }
    }

    func setSurroundEnabled(_ on: Bool) {
        writeSound(\.surroundEnabled, on) { ip, val in
            await Self.setEQ(ip, "SurroundEnable", val ? 1 : 0)
        }
    }

    func setSurroundLevel(_ v: Int) {
        writeSound(\.surroundLevel, max(-15, min(15, v))) { ip, val in
            await Self.setEQ(ip, "SurroundLevel", val)
        }
    }

    func setMusicSurroundLevel(_ v: Int) {
        writeSound(\.musicSurroundLevel, max(-15, min(15, v))) { ip, val in
            await Self.setEQ(ip, "MusicSurroundLevel", val)
        }
    }

    /// Ambient plays only atmospheric content through the rears; Full sends
    /// them the whole mix.
    func setMusicFull(_ full: Bool) {
        writeSound(\.musicFull, full) { ip, val in
            await Self.setEQ(ip, "SurroundMode", val ? 1 : 0)
        }
    }

    /// Apply locally at once, then send. Throttled per control so dragging the
    /// bass slider can't swallow a loudness toggle queued behind it.
    private func writeSound<V: Sendable & Equatable>(
        _ key: WritableKeyPath<SoundSettings, V>,
        _ value: V,
        send: @escaping @Sendable (String, V) async -> Void
    ) {
        guard var s = sound, let room = currentSoundRoom, s[keyPath: key] != value else { return }
        s[keyPath: key] = value
        sound = s
        let ip = room.ip
        throttler("sound:\(room.uuid):\(key.hashValue)").call { await send(ip, value) }
    }

    // MARK: - Network

    nonisolated static func setEQ(_ ip: String, _ type: String, _ value: Int) async {
        _ = try? await SOAP.call(.renderingControl, action: "SetEQ",
                                 args: [("InstanceID", "0"), ("EQType", type),
                                        ("DesiredValue", "\(value)")],
                                 host: ip)
    }

    /// Reads everything in one parallel burst.
    ///
    /// Capability is decided by the caller, not by whether the query answers:
    /// a player with no Sub still returns a `SubGain` value quite happily, so
    /// asking it proves nothing. The Sub comes from the topology's channel
    /// map and home theater from the model name, and the queries that don't
    /// apply are never sent.
    nonisolated static func fetchSound(ip: String,
                                       hasSub: Bool,
                                       hasSurrounds: Bool,
                                       homeTheater: Bool) async -> SoundSettings {
        var s = SoundSettings()
        s.hasSub = hasSub
        s.hasSurrounds = hasSurrounds
        s.isHomeTheater = homeTheater

        @Sendable func get(_ action: String, _ args: [(String, String)] = []) async -> String? {
            try? await SOAP.call(.renderingControl, action: action,
                                 args: [("InstanceID", "0")] + args, host: ip)
        }
        @Sendable func eq(_ type: String) async -> String? {
            await get("GetEQ", [("EQType", type)]).flatMap { SOAP.value("CurrentValue", in: $0) }
        }
        @Sendable func eq(_ type: String, when supported: Bool) async -> String? {
            supported ? await eq(type) : nil
        }

        async let bassR = get("GetBass")
        async let trebleR = get("GetTreble")
        async let loudR = get("GetLoudness", [("Channel", "Master")])
        async let fixedR = get("GetOutputFixed")
        async let subGainR = eq("SubGain", when: hasSub)
        async let subEnableR = eq("SubEnable", when: hasSub)
        async let nightR = eq("NightMode", when: homeTheater)
        async let dialogR = eq("DialogLevel", when: homeTheater)
        async let surrOnR = eq("SurroundEnable", when: hasSurrounds)
        async let surrTVR = eq("SurroundLevel", when: hasSurrounds)
        async let surrMusicR = eq("MusicSurroundLevel", when: hasSurrounds)
        async let surrModeR = eq("SurroundMode", when: hasSurrounds)

        if let r = await bassR, let v = SOAP.value("CurrentBass", in: r).flatMap({ Int($0) }) {
            s.bass = v
        }
        if let r = await trebleR, let v = SOAP.value("CurrentTreble", in: r).flatMap({ Int($0) }) {
            s.treble = v
        }
        if let r = await loudR, let v = SOAP.value("CurrentLoudness", in: r) {
            s.loudness = v == "1"
        }
        if let r = await fixedR, let v = SOAP.value("CurrentFixed", in: r) {
            s.outputFixed = v == "1"
        }
        if let v = await subGainR, let n = Int(v) {
            s.subGain = n
        }
        if let v = await subEnableR {
            s.subEnabled = v == "1"
        }
        if let v = await nightR {
            s.nightMode = v == "1"
        }
        if let v = await dialogR {
            s.dialogLevel = v == "1"
        }
        if let v = await surrOnR {
            s.surroundEnabled = v == "1"
        }
        if let v = await surrTVR, let n = Int(v) {
            s.surroundLevel = n
        }
        if let v = await surrMusicR, let n = Int(v) {
            s.musicSurroundLevel = n
        }
        if let v = await surrModeR {
            s.musicFull = v == "1"
        }
        return s
    }
}

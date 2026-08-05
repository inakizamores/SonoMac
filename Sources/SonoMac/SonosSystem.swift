import Foundation
import Observation
import ServiceManagement

/// Runs queued work strictly in order. Two commands to the same speaker that
/// race can land inverted — a second play/pause tap arriving before the first
/// leaves the speaker and the panel disagreeing until the next poll.
@MainActor
final class SerialQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ op: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await op()
        }
    }
}

/// Trailing-edge throttler so slider drags send at most ~8 requests/sec.
/// Sends are chained rather than fired independently: they are the same
/// control being written repeatedly, so an earlier value overtaking a later
/// one on the wire would snap the speaker back to a level you already left.
@MainActor
final class Throttler {
    private let interval: TimeInterval
    private var lastFire: Date = .distantPast
    private var pending: Task<Void, Never>?
    private let queue = SerialQueue()

    init(interval: TimeInterval = 0.12) { self.interval = interval }

    func call(_ op: @escaping @Sendable () async -> Void) {
        pending?.cancel()
        let wait = interval - Date().timeIntervalSince(lastFire)
        pending = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.lastFire = Date()
            self.queue.enqueue(op)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SonoMac: launch at login failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
@Observable
final class SonosSystem {
    var groups: [SonosGroup] = []
    var masterVolume: Double = 0
    var isScanning = false
    var launchAtLogin = LoginItem.isEnabled
    var models: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "models") as? [String: String]) ?? [:]

    // Sound settings section (per room, fetched on demand — see Sound.swift)
    var soundExpanded = UserDefaults.standard.bool(forKey: "soundExpanded")
    var soundRoom = UserDefaults.standard.string(forKey: "soundRoom") ?? ""
    var sound: SoundSettings?

    var allMuted: Bool { !groups.isEmpty && groups.allSatisfy(\.muted) }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var menuIsOpen = false
    @ObservationIgnored private var pollTick = 0
    @ObservationIgnored private var settling = false
    @ObservationIgnored private var scanInFlight = false
    /// Bumped by every grouping action. An older settle that sees a newer
    /// generation abandons quietly instead of fighting for the topology it
    /// was waiting on — two quick regroups used to leave the panel stuck on
    /// whichever one happened to finish spinning last.
    @ObservationIgnored private var regroupGeneration = 0
    @ObservationIgnored var expandedGroups: Set<String> = []
    @ObservationIgnored private var suppressUntil: [String: Date] = [:]
    @ObservationIgnored private var throttlers: [String: Throttler] = [:]
    @ObservationIgnored private var queues: [String: SerialQueue] = [:]
    @ObservationIgnored var masterBase: [String: Int]?
    @ObservationIgnored var masterStart: Double = 0
    // Frozen volume ratios captured at drag start (mirrors the device's
    // SnapshotGroupVolume) so member levels never drift from rounding.
    @ObservationIgnored var groupDragBase: [String: (group: Int, members: [String: Int])] = [:]

    init() {
        restoreState()
        Task { await initialLoad() }
    }

    /// Last-known rooms and state, so the panel renders fully populated the
    /// instant it opens — even right after login — instead of flashing the
    /// scanning layout and then popping content in. Live values glide in
    /// on top once the speakers answer.
    private func restoreState() {
        guard let data = UserDefaults.standard.data(forKey: "lastGroups"),
              let saved = try? JSONDecoder().decode([SonosGroup].self, from: data),
              !saved.isEmpty
        else { return }
        groups = saved
        syncMaster()
    }

    private func persistState() {
        guard !groups.isEmpty,
              let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: "lastGroups")
    }

    // MARK: - Menu lifecycle

    func menuOpened() {
        menuIsOpen = true
        // Re-read rather than trust the value cached at launch: the login item
        // can equally be changed from System Settings.
        launchAtLogin = LoginItem.isEnabled
        if soundExpanded { Task { await loadSound() } }
        pollTask?.cancel()
        pollTask = Task {
            if groups.isEmpty {
                await initialLoad()
            } else {
                await refreshTopologyQuiet()
                await refreshState()
            }
            while !Task.isCancelled && menuIsOpen {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard menuIsOpen, !Task.isCancelled else { break }
                pollTick += 1
                if pollTick % 3 == 0 { await refreshTopologyQuiet() }
                await refreshState()
            }
        }
    }

    func menuClosed() {
        menuIsOpen = false
        pollTask?.cancel()
        pollTask = nil
        persistState()
        // Keyed partly by group ID, which Sonos renumbers on every grouping
        // change, so these accumulate dead entries for the life of the
        // process. Nothing is mid-drag once the panel is shut.
        suppressUntil.removeAll()
        throttlers.removeAll()
        queues.removeAll()
        groupDragBase.removeAll()
        masterBase = nil
    }

    // MARK: - Discovery / topology

    private var knownIPs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "knownIPs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "knownIPs") }
    }

    func initialLoad() async {
        guard !scanInFlight else { return }
        scanInFlight = true
        isScanning = groups.isEmpty
        defer { scanInFlight = false; isScanning = false }

        if let found = await Self.firstTopology(knownIPs) {
            applyTopology(found)
            await refreshState()
            return
        }
        let discovered = await SSDP.discover()
        if let found = await Self.firstTopology(Array(discovered)) {
            applyTopology(found)
            await refreshState()
        }
    }

    func rescan() {
        guard !scanInFlight else { return }
        Task {
            scanInFlight = true
            isScanning = true
            defer { scanInFlight = false; isScanning = false }
            let discovered = await SSDP.discover(timeout: 3)
            let candidates = Array(Set(discovered).union(knownIPs))
            if let found = await Self.firstTopology(candidates) {
                applyTopology(found)
                await refreshState()
            }
            isScanning = false
        }
    }

    func refreshTopologyQuiet() async {
        // While a regroup is settling the speakers are still publishing the
        // old arrangement; letting the poll apply it would flip the panel back.
        guard !settling else { return }
        if let found = await Self.firstTopology(knownIPs) {
            applyTopology(found)
        }
    }

    /// Which speakers sit together, ignoring group IDs (Sonos renumbers them
    /// on every change) and coordinator identity (the speakers elect that
    /// themselves, and it isn't what the panel's layout depends on).
    nonisolated static func partition(_ gs: [SonosGroup]) -> String {
        gs.map { $0.members.map(\.uuid).sorted().joined(separator: ",") }
            .sorted()
            .joined(separator: "|")
    }

    /// Wait for the speakers to reach the arrangement we asked for.
    ///
    /// Renegotiation is asynchronous and Sonos publishes transient
    /// arrangements on the way — separating a pair can briefly report both
    /// rooms still grouped under whichever player kept the audio. Applying
    /// the first topology that merely *differs* renders those transients as
    /// real layout changes, which is what made separating look like it
    /// regrouped before finally splitting. So match the target and ignore
    /// everything else until it arrives.
    func settleTopology(expecting expected: String,
                        generation: Int,
                        resend: @escaping () async -> Void) async {
        settling = true
        defer { if isCurrentRegroup(generation) { settling = false } }

        for attempt in 0..<14 {
            // A newer grouping action has taken over; its own settle owns the
            // topology now, and finishing ours would undo it.
            guard isCurrentRegroup(generation) else { return }

            if let fresh = await Self.firstTopology(knownIPs),
               Self.partition(fresh) == expected {
                applyTopology(fresh)
                await refreshState()
                // Hold the poll off a moment longer: a late transient landing
                // right after we commit would flip the panel straight back.
                try? await Task.sleep(nanoseconds: 600_000_000)
                return
            }
            // Halfway with nothing to show for it: assume a command was
            // dropped rather than merely slow, and say it again. Joining and
            // leaving are both idempotent, so a duplicate costs nothing.
            if attempt == 6 { await resend() }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // Never reached it. Truth wins over our optimistic layout, promptly —
        // a wrong panel you can correct beats a wrong panel that lingers.
        guard isCurrentRegroup(generation) else { return }
        settling = false
        await refreshTopologyQuiet()
        await refreshState()
    }

    /// Merge fresh topology, preserving live volume/transport state we already know.
    private func applyTopology(_ fresh: [SonosGroup]) {
        var oldMembers: [String: SonosSpeaker] = [:]
        for g in groups { for m in g.members { oldMembers[m.uuid] = m } }
        let oldGroups = groups

        var merged: [SonosGroup] = []
        for var f in fresh {
            f.members = f.members.map { m in
                var m = m
                if let o = oldMembers[m.uuid] { m.volume = o.volume; m.muted = o.muted }
                return m
            }
            // Match on coordinator too: Sonos renumbers group IDs on every
            // grouping change, so an ID-only match would drop the live state
            // of a group that merely gained or lost a speaker.
            if let o = oldGroups.first(where: { $0.id == f.id })
                ?? oldGroups.first(where: { $0.coordinatorUUID == f.coordinatorUUID }) {
                f.volume = o.volume
                f.muted = o.muted
                f.transportState = o.transportState
                f.nowPlaying = o.nowPlaying
                f.isTVInput = o.isTVInput
            }
            merged.append(f)
        }
        groups = merged.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let ips = Array(Set(groups.flatMap { $0.members.map(\.ip) })).sorted()
        if !ips.isEmpty { knownIPs = ips }
        expandedGroups.formIntersection(Set(groups.map(\.key)))
        persistState()

        // Bonding comes from the topology and isn't cached, so a Sound section
        // opened before the first topology landed drew without it.
        if soundExpanded, let room = currentSoundRoom, let s = sound,
           s.hasSub != room.hasSub || s.hasSurrounds != room.hasSurrounds {
            Task { await loadSound() }
        }
    }

    // MARK: - State refresh

    func refreshState() async {
        let snapshot = groups
        guard !snapshot.isEmpty else { return }
        let updated = await withTaskGroup(of: SonosGroup.self) { tg in
            for g in snapshot { tg.addTask { await Self.groupState(g) } }
            var out: [SonosGroup] = []
            for await g in tg { out.append(g) }
            return out
        }
        apply(updated)
        for g in groups where expandedGroups.contains(g.key) {
            await refreshMemberVolumes(g.key)
        }
        await ensureModels()
    }

    private func apply(_ updated: [SonosGroup]) {
        for u in updated {
            guard let i = groups.firstIndex(where: { $0.id == u.id }) else { continue }
            var g = groups[i]
            if !suppressed("v:\(u.id)") { g.volume = u.volume; g.muted = u.muted }
            if !suppressed("t:\(u.id)") {
                g.transportState = u.transportState
                g.isTVInput = u.isTVInput
                // Under the same guard as the transport it describes:
                // otherwise an optimistic "TV Audio" is overwritten by one
                // stale poll before the speaker catches up, and the label
                // flickers back to the old track.
                g.nowPlaying = u.nowPlaying
            }
            g.online = u.online
            groups[i] = g
        }
        syncMaster()
    }

    /// Recompute the master bar from the current group levels. Poll-driven
    /// callers honour the post-drag suppression window so a stale device echo
    /// can't yank the bar back; local edits pass `force`, since the values
    /// they just wrote are authoritative and the bar must track them at once.
    func syncMaster(force: Bool = false) {
        guard masterBase == nil, force || !suppressed("master"), !groups.isEmpty else { return }
        masterVolume = Double(groups.map(\.volume).reduce(0, +)) / Double(groups.count)
    }

    func refreshMemberVolumes(_ key: String) async {
        guard let g = groups.first(where: { $0.key == key }), g.members.count > 1 else { return }
        let members = g.members
        var vols: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { tg in
            for m in members { tg.addTask { (m.uuid, await Self.playerVolume(m.ip)) } }
            for await (uuid, v) in tg { if let v { vols[uuid] = v } }
        }
        guard let i = groups.firstIndex(where: { $0.key == key }) else { return }
        for j in groups[i].members.indices {
            let uuid = groups[i].members[j].uuid
            if let v = vols[uuid], !suppressed("m:\(uuid)") {
                groups[i].members[j].volume = v
            }
        }
    }

    // MARK: - Model names (for TV/home-theater capability)

    func ensureModels() async {
        let missing = groups.flatMap(\.members).filter { models[$0.uuid] == nil }
        guard !missing.isEmpty else { return }
        var updated = models
        await withTaskGroup(of: (String, String)?.self) { tg in
            for m in missing {
                tg.addTask {
                    guard let name = await Self.fetchModel(ip: m.ip) else { return nil }
                    return (m.uuid, name)
                }
            }
            for await pair in tg { if let (uuid, name) = pair { updated[uuid] = name } }
        }
        if updated != models {
            models = updated
            UserDefaults.standard.set(updated, forKey: "models")
        }
    }

    func htCapable(_ uuid: String) -> Bool {
        guard let model = models[uuid]?.lowercased() else { return false }
        return ["arc", "beam", "ray", "playbar", "playbase", "amp", "theater"]
            .contains { model.contains($0) }
    }

    // MARK: - Suppression (ignore poll echoes right after local changes)

    func suppress(_ key: String, _ ttl: TimeInterval = 1.5) {
        suppressUntil[key] = Date().addingTimeInterval(ttl)
    }

    func suppressed(_ key: String) -> Bool {
        (suppressUntil[key] ?? .distantPast) > Date()
    }

    func throttler(_ key: String) -> Throttler {
        if let t = throttlers[key] { return t }
        let t = Throttler()
        throttlers[key] = t
        return t
    }

    /// Ordered command channel, keyed per group or per speaker.
    func queue(_ key: String) -> SerialQueue {
        if let q = queues[key] { return q }
        let q = SerialQueue()
        queues[key] = q
        return q
    }

    func nextRegroupGeneration() -> Int {
        regroupGeneration += 1
        return regroupGeneration
    }

    func isCurrentRegroup(_ generation: Int) -> Bool {
        generation == regroupGeneration
    }

    // MARK: - Static network helpers

    nonisolated static func firstTopology(_ ips: [String]) async -> [SonosGroup]? {
        guard !ips.isEmpty else { return nil }
        return await withTaskGroup(of: [SonosGroup]?.self) { tg in
            for ip in ips { tg.addTask { try? await Self.fetchTopology(from: ip) } }
            for await result in tg {
                if let result, !result.isEmpty {
                    tg.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    nonisolated static func fetchTopology(from ip: String) async throws -> [SonosGroup] {
        let resp = try await SOAP.call(.zoneGroupTopology, action: "GetZoneGroupState", host: ip)
        guard let escaped = SOAP.value("ZoneGroupState", in: resp) else { throw SonosError.badResponse }
        let groups = TopologyParser.parse(SOAP.xmlUnescape(escaped))
        guard !groups.isEmpty else { throw SonosError.badResponse }
        return groups
    }

    nonisolated static func groupState(_ g: SonosGroup) async -> SonosGroup {
        var g = g
        let ip = g.coordinator.ip
        async let volR = SOAP.call(.groupRenderingControl, action: "GetGroupVolume",
                                   args: [("InstanceID", "0")], host: ip)
        async let muteR = SOAP.call(.groupRenderingControl, action: "GetGroupMute",
                                    args: [("InstanceID", "0")], host: ip)
        async let transR = SOAP.call(.avTransport, action: "GetTransportInfo",
                                     args: [("InstanceID", "0")], host: ip)
        async let mediaR = SOAP.call(.avTransport, action: "GetMediaInfo",
                                     args: [("InstanceID", "0")], host: ip)
        async let posR = SOAP.call(.avTransport, action: "GetPositionInfo",
                                   args: [("InstanceID", "0")], host: ip)

        if let r = try? await volR, let v = SOAP.value("CurrentVolume", in: r).flatMap({ Int($0) }) {
            g.volume = v
        }
        if let r = try? await muteR, let m = SOAP.value("CurrentMute", in: r) {
            g.muted = m == "1"
        }
        // Transport is supported by every player, so answering it at all is
        // the reachability signal. Without one, an unplugged speaker keeps a
        // fully live-looking card whose controls quietly do nothing.
        let transport = try? await transR
        g.online = transport != nil
        if let r = transport, let s = SOAP.value("CurrentTransportState", in: r) {
            g.transportState = TransportState(upnp: s)
        }
        if let r = try? await mediaR, let uri = SOAP.value("CurrentURI", in: r) {
            g.isTVInput = uri.hasPrefix("x-sonos-htastream")
        }
        if g.isTVInput {
            g.nowPlaying = "TV Audio"
        } else if let r = try? await posR,
                  let meta = SOAP.value("TrackMetaData", in: r),
                  meta != "NOT_IMPLEMENTED", !meta.isEmpty {
            let didl = SOAP.xmlUnescape(meta)
            let title = SOAP.value("dc:title", in: didl).map(SOAP.xmlUnescape) ?? ""
            let artist = SOAP.value("dc:creator", in: didl).map(SOAP.xmlUnescape) ?? ""
            g.nowPlaying = artist.isEmpty ? title : "\(title) — \(artist)"
        } else {
            g.nowPlaying = ""
        }
        _ = try? await posR
        return g
    }

    nonisolated static func playerVolume(_ ip: String) async -> Int? {
        guard let r = try? await SOAP.call(.renderingControl, action: "GetVolume",
                                           args: [("InstanceID", "0"), ("Channel", "Master")],
                                           host: ip)
        else { return nil }
        return SOAP.value("CurrentVolume", in: r).flatMap { Int($0) }
    }

    nonisolated static func setPlayerVolume(_ ip: String, _ v: Int,
                                            retry: Bool = false) async {
        _ = try? await SOAP.call(.renderingControl, action: "SetVolume",
                                 args: [("InstanceID", "0"), ("Channel", "Master"),
                                        ("DesiredVolume", "\(v)")],
                                 host: ip, retry: retry)
    }

    nonisolated static func fetchModel(ip: String) async -> String? {
        guard let url = URL(string: "http://\(ip):1400/xml/device_description.xml"),
              let (data, _) = try? await SOAP.session.data(from: url),
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        return SOAP.value("modelName", in: xml)
    }
}

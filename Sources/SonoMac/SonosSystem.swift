import Foundation
import Observation
import ServiceManagement

/// Trailing-edge throttler so slider drags send at most ~8 requests/sec.
@MainActor
final class Throttler {
    private let interval: TimeInterval
    private var lastFire: Date = .distantPast
    private var pending: Task<Void, Never>?

    init(interval: TimeInterval = 0.12) { self.interval = interval }

    func call(_ op: @escaping @Sendable () async -> Void) {
        pending?.cancel()
        pending = nil
        let elapsed = Date().timeIntervalSince(lastFire)
        if elapsed >= interval {
            lastFire = Date()
            Task.detached(priority: .userInitiated) { await op() }
        } else {
            pending = Task {
                try? await Task.sleep(nanoseconds: UInt64((self.interval - elapsed) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.lastFire = Date()
                await op()
            }
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

    var allMuted: Bool { !groups.isEmpty && groups.allSatisfy(\.muted) }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var menuIsOpen = false
    @ObservationIgnored private var pollTick = 0
    @ObservationIgnored var expandedGroups: Set<String> = []
    @ObservationIgnored private var suppressUntil: [String: Date] = [:]
    @ObservationIgnored private var throttlers: [String: Throttler] = [:]
    @ObservationIgnored var masterBase: [String: Int]?
    @ObservationIgnored var masterStart: Double = 0

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
                if pollTick % 8 == 0 { await refreshTopologyQuiet() }
                await refreshState()
            }
        }
    }

    func menuClosed() {
        menuIsOpen = false
        pollTask?.cancel()
        pollTask = nil
        persistState()
    }

    // MARK: - Discovery / topology

    private var knownIPs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "knownIPs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "knownIPs") }
    }

    func initialLoad() async {
        guard !isScanning else { return }
        isScanning = groups.isEmpty
        defer { isScanning = false }

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
        Task {
            isScanning = true
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
        if let found = await Self.firstTopology(knownIPs) {
            applyTopology(found)
        }
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
            if let o = oldGroups.first(where: { $0.id == f.id }) {
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
        persistState()
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
        for id in expandedGroups { await refreshMemberVolumes(id) }
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
            }
            g.nowPlaying = u.nowPlaying
            groups[i] = g
        }
        syncMaster()
    }

    func syncMaster() {
        guard masterBase == nil, !suppressed("master"), !groups.isEmpty else { return }
        masterVolume = Double(groups.map(\.volume).reduce(0, +)) / Double(groups.count)
    }

    func refreshMemberVolumes(_ id: String) async {
        guard let g = groups.first(where: { $0.id == id }), g.members.count > 1 else { return }
        let members = g.members
        var vols: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { tg in
            for m in members { tg.addTask { (m.uuid, await Self.playerVolume(m.ip)) } }
            for await (uuid, v) in tg { if let v { vols[uuid] = v } }
        }
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
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
        if let r = try? await transR, let s = SOAP.value("CurrentTransportState", in: r) {
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

    nonisolated static func setPlayerVolume(_ ip: String, _ v: Int) async {
        _ = try? await SOAP.call(.renderingControl, action: "SetVolume",
                                 args: [("InstanceID", "0"), ("Channel", "Master"),
                                        ("DesiredVolume", "\(v)")],
                                 host: ip)
    }

    nonisolated static func fetchModel(ip: String) async -> String? {
        guard let url = URL(string: "http://\(ip):1400/xml/device_description.xml"),
              let (data, _) = try? await SOAP.session.data(from: url),
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        return SOAP.value("modelName", in: xml)
    }
}

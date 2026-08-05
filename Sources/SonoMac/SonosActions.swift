import Foundation
import AppKit

// MARK: - User actions

extension SonosSystem {

    // MARK: Volume

    /// Snapshot ratios at drag start — on the device (SnapshotGroupVolume,
    /// so its distribution math never compounds rounding) and locally (so
    /// member bars track the group slider in real time, staying even if
    /// they started even).
    func groupEditing(_ id: String, _ editing: Bool) {
        if editing {
            guard groupDragBase[id] == nil,
                  let g = groups.first(where: { $0.id == id }) else { return }
            groupDragBase[id] = (g.volume,
                                 Dictionary(uniqueKeysWithValues: g.members.map { ($0.uuid, $0.volume) }))
            let ip = g.coordinator.ip
            Task {
                _ = try? await SOAP.call(.groupRenderingControl, action: "SnapshotGroupVolume",
                                         args: [("InstanceID", "0")], host: ip)
            }
        } else {
            groupDragBase[id] = nil
            if let g = groups.first(where: { $0.id == id }) {
                suppress("v:\(id)", 1.2)
                for m in g.members { suppress("m:\(m.uuid)", 1.2) }
                confirm("v:\(id)", ip: g.coordinator.ip) { ip in
                    _ = try? await SOAP.call(.groupRenderingControl, action: "SetGroupVolume",
                                             args: [("InstanceID", "0"),
                                                    ("DesiredVolume", "\(g.volume)")],
                                             host: ip, retry: true)
                }
            }
        }
    }

    /// Per-speaker equivalent of `groupEditing`, for the sliders in an
    /// expanded room.
    func memberEditing(_ groupID: String, _ uuid: String, _ editing: Bool) {
        guard !editing,
              let g = groups.first(where: { $0.id == groupID }),
              let m = g.members.first(where: { $0.uuid == uuid }) else { return }
        suppress("m:\(uuid)", 1.2)
        confirm("m:\(uuid)", ip: m.ip) { ip in
            await Self.setPlayerVolume(ip, m.volume, retry: true)
        }
    }

    /// Re-send the value a drag ended on, with retries.
    ///
    /// Mid-drag writes are deliberately fire-and-forget: each one is
    /// superseded a moment later, so a dropped packet costs nothing and
    /// retrying would stall the send chain behind a 3s timeout. The value you
    /// release on is different — nothing follows it. If that one is dropped
    /// the speaker sits at a level you never chose while the panel shows the
    /// one you did, and no poll corrects the speaker.
    private func confirm(_ key: String, ip: String,
                         _ send: @escaping @Sendable (String) async -> Void) {
        queue("confirm:\(key)").enqueue { await send(ip) }
    }

    func setGroupVolume(_ id: String, _ value: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let v = max(0, min(100, value))
        if groupDragBase[id] == nil { groupEditing(id, true) }
        groups[i].volume = v
        // Mirror the device's snapshot-scaled distribution locally.
        if let base = groupDragBase[id] {
            for j in groups[i].members.indices {
                let uuid = groups[i].members[j].uuid
                let b = base.members[uuid] ?? v
                groups[i].members[j].volume = base.group > 0
                    ? min(100, Int((Double(b) * Double(v) / Double(base.group)).rounded()))
                    : v
            }
        }
        suppress("v:\(id)")
        for m in groups[i].members { suppress("m:\(m.uuid)") }
        syncMaster(force: true)
        let ip = groups[i].coordinator.ip
        throttler("gv:\(id)").call {
            _ = try? await SOAP.call(.groupRenderingControl, action: "SetGroupVolume",
                                     args: [("InstanceID", "0"), ("DesiredVolume", "\(v)")],
                                     host: ip)
        }
    }

    func setMemberVolume(_ groupID: String, _ uuid: String, _ value: Int) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }),
              let mi = groups[gi].members.firstIndex(where: { $0.uuid == uuid })
        else { return }
        let v = max(0, min(100, value))
        groups[gi].members[mi].volume = v
        suppress("m:\(uuid)")
        suppress("v:\(groupID)")
        // The device reports group volume as the mean of its players, so
        // mirror that locally — otherwise the room bar (and the master bar
        // above it) sit stale until the next poll.
        let vols = groups[gi].members.map(\.volume)
        groups[gi].volume = Int((Double(vols.reduce(0, +)) / Double(vols.count)).rounded())
        syncMaster(force: true)
        let ip = groups[gi].members[mi].ip
        throttler("mv:\(uuid)").call {
            await Self.setPlayerVolume(ip, v)
        }
    }

    func masterEditing(_ editing: Bool) {
        if editing {
            masterBase = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.volume) })
            masterStart = masterVolume
            for g in groups { groupEditing(g.id, true) }
        } else {
            masterBase = nil
            for g in groups { groupEditing(g.id, false) }
            suppress("master", 1.2)
        }
    }

    func setMasterVolume(_ value: Double) {
        if masterBase == nil { masterEditing(true) }
        masterVolume = value
        suppress("master")
        guard let base = masterBase else { return }
        let delta = Int((value - masterStart).rounded())
        for (id, b) in base {
            setGroupVolume(id, b + delta)
        }
    }

    // MARK: Mute

    func toggleMute(_ id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = !groups[i].muted
        groups[i].muted = target
        suppress("v:\(id)")
        let ip = groups[i].coordinator.ip
        queue("cmd:\(id)").enqueue {
            _ = try? await SOAP.call(.groupRenderingControl, action: "SetGroupMute",
                                     args: [("InstanceID", "0"), ("DesiredMute", target ? "1" : "0")],
                                     host: ip, retry: true)
        }
    }

    func toggleMuteAll() {
        let target = !allMuted
        for i in groups.indices {
            groups[i].muted = target
            suppress("v:\(groups[i].id)")
            let ip = groups[i].coordinator.ip
            queue("cmd:\(groups[i].id)").enqueue {
                _ = try? await SOAP.call(.groupRenderingControl, action: "SetGroupMute",
                                         args: [("InstanceID", "0"), ("DesiredMute", target ? "1" : "0")],
                                         host: ip, retry: true)
            }
        }
    }

    // MARK: Playback

    func playPause(_ id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let wasPlaying = groups[i].transportState == .playing
            || groups[i].transportState == .transitioning
        groups[i].transportState = wasPlaying ? .paused : .playing
        suppress("t:\(id)", 2.0)
        let ip = groups[i].coordinator.ip
        queue("cmd:\(id)").enqueue {
            if wasPlaying {
                _ = try? await SOAP.call(.avTransport, action: "Pause",
                                         args: [("InstanceID", "0")], host: ip, retry: true)
            } else {
                _ = try? await SOAP.call(.avTransport, action: "Play",
                                         args: [("InstanceID", "0"), ("Speed", "1")],
                                         host: ip, retry: true)
            }
        }
    }

    func next(_ id: String) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        let ip = g.coordinator.ip
        queue("cmd:\(id)").enqueue {
            _ = try? await SOAP.call(.avTransport, action: "Next",
                                     args: [("InstanceID", "0")], host: ip, retry: true)
        }
    }

    func previous(_ id: String) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        let ip = g.coordinator.ip
        queue("cmd:\(id)").enqueue {
            _ = try? await SOAP.call(.avTransport, action: "Previous",
                                     args: [("InstanceID", "0")], host: ip, retry: true)
        }
    }

    // MARK: Even out volumes (like the new Sonos app)

    func evenOut(_ id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }),
              groups[i].members.count > 1 else { return }
        let vols = groups[i].members.map(\.volume)
        let target = Int((Double(vols.reduce(0, +)) / Double(vols.count)).rounded())
        let members = groups[i].members
        for j in groups[i].members.indices {
            groups[i].members[j].volume = target
            suppress("m:\(groups[i].members[j].uuid)", 2.5)
        }
        groups[i].volume = target
        suppress("v:\(id)", 2.5)
        syncMaster(force: true)
        Task {
            await withTaskGroup(of: Void.self) { tg in
                for m in members {
                    tg.addTask { await Self.setPlayerVolume(m.ip, target) }
                }
            }
        }
    }

    /// System-wide levelling: every speaker in every room to one level, the
    /// mean across the whole system.
    ///
    /// Reads every player first rather than averaging what we hold: a room's
    /// per-speaker levels are only polled while it's expanded, so a collapsed
    /// room's members sit at 0 in memory and would drag the mean to nothing.
    func evenOutAll() {
        let members = groups.flatMap(\.members)
        guard members.count > 1 else { return }
        Task {
            var levels: [String: Int] = [:]
            await withTaskGroup(of: (String, Int?).self) { tg in
                for m in members { tg.addTask { (m.uuid, await Self.playerVolume(m.ip)) } }
                for await (uuid, v) in tg { if let v { levels[uuid] = v } }
            }
            guard !levels.isEmpty else { return }
            let target = Int((Double(levels.values.reduce(0, +)) / Double(levels.count)).rounded())

            for i in groups.indices {
                for j in groups[i].members.indices {
                    groups[i].members[j].volume = target
                    suppress("m:\(groups[i].members[j].uuid)", 2.5)
                }
                groups[i].volume = target
                suppress("v:\(groups[i].id)", 2.5)
            }
            syncMaster(force: true)

            await withTaskGroup(of: Void.self) { tg in
                for m in members { tg.addTask { await Self.setPlayerVolume(m.ip, target) } }
            }
        }
    }

    // MARK: TV input

    func toggleTV(_ id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let coord = groups[i].coordinator
        let toTV = !groups[i].isTVInput
        groups[i].isTVInput = toTV
        groups[i].nowPlaying = toTV ? "TV Audio" : ""
        if toTV { groups[i].transportState = .playing }
        suppress("t:\(id)", 3.0)
        queue("cmd:\(id)").enqueue {
            if toTV {
                _ = try? await SOAP.call(.avTransport, action: "SetAVTransportURI",
                                         args: [("InstanceID", "0"),
                                                ("CurrentURI", "x-sonos-htastream:\(coord.uuid):spdif"),
                                                ("CurrentURIMetaData", "")],
                                         host: coord.ip)
                _ = try? await SOAP.call(.avTransport, action: "Play",
                                         args: [("InstanceID", "0"), ("Speed", "1")], host: coord.ip)
            } else {
                _ = try? await SOAP.call(.avTransport, action: "SetAVTransportURI",
                                         args: [("InstanceID", "0"),
                                                ("CurrentURI", "x-rincon-queue:\(coord.uuid)#0"),
                                                ("CurrentURIMetaData", "")],
                                         host: coord.ip)
            }
        }
    }

    // MARK: Grouping

    /// Restructure the local group list right away, so the panel shows the new
    /// layout on click. Speakers take a beat to renegotiate and their first
    /// topology answer still describes the old arrangement, so without this the
    /// UI sits unchanged for a second or more. `settleTopology` replaces this
    /// with the confirmed truth the moment it lands.
    @discardableResult
    private func regroupLocally(_ movers: [SonosSpeaker], joining coordUUID: String?) -> String {
        let moverIDs = Set(movers.map(\.uuid))
        // A speaker's own level is only polled while its room is expanded, so
        // a collapsed room's members read 0. Fall back to the group level,
        // which is always fresh, when standing a speaker up on its own —
        // otherwise a newly separated room flashes at zero volume.
        var level: [String: (volume: Int, muted: Bool)] = [:]
        for g in groups {
            for m in g.members {
                level[m.uuid] = (m.volume > 0 ? m.volume : g.volume, g.muted)
            }
        }
        var rebuilt: [SonosGroup] = []

        for g in groups {
            let kept = g.members.filter { !moverIDs.contains($0.uuid) }
            guard !kept.isEmpty else { continue }
            if kept.contains(where: { $0.uuid == g.coordinatorUUID }) {
                var g = g
                g.members = kept
                rebuilt.append(g)
            } else {
                // The coordinator itself left; promote whoever remains. Sonos
                // elects its own, which may differ — harmless, since the
                // partition we wait on ignores coordinator identity.
                rebuilt.append(SonosGroup(id: "pending:\(kept[0].uuid)",
                                          coordinatorUUID: kept[0].uuid,
                                          members: kept,
                                          volume: g.volume,
                                          muted: g.muted))
            }
        }

        if let coordUUID, let ti = rebuilt.firstIndex(where: { $0.coordinatorUUID == coordUUID }) {
            rebuilt[ti].members.append(contentsOf: movers)
            rebuilt[ti].members.sort { a, b in
                if a.uuid == coordUUID { return true }
                if b.uuid == coordUUID { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } else {
            for m in movers {
                rebuilt.append(SonosGroup(id: "pending:\(m.uuid)",
                                          coordinatorUUID: m.uuid,
                                          members: [m],
                                          volume: level[m.uuid]?.volume ?? m.volume,
                                          muted: level[m.uuid]?.muted ?? false))
            }
        }

        groups = rebuilt.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        syncMaster(force: true)
        return Self.partition(groups)
    }

    private func join(_ members: [SonosSpeaker], to coordUUID: String) async {
        await withTaskGroup(of: Void.self) { tg in
            for m in members {
                tg.addTask {
                    _ = try? await SOAP.call(.avTransport, action: "SetAVTransportURI",
                                             args: [("InstanceID", "0"),
                                                    ("CurrentURI", "x-rincon:\(coordUUID)"),
                                                    ("CurrentURIMetaData", "")],
                                             host: m.ip, retry: true)
                }
            }
        }
    }

    private func standalone(_ members: [SonosSpeaker]) async {
        await withTaskGroup(of: Void.self) { tg in
            for m in members {
                tg.addTask {
                    _ = try? await SOAP.call(.avTransport,
                                             action: "BecomeCoordinatorOfStandaloneGroup",
                                             args: [("InstanceID", "0")],
                                             host: m.ip, retry: true)
                }
            }
        }
    }

    /// The single path every grouping change takes: draw the result at once,
    /// send the commands, then wait for the speakers to actually reach that
    /// arrangement — re-sending once if they seem to have missed it, and
    /// standing down if a newer action has superseded this one.
    private func regroup(_ movers: [SonosSpeaker], joining coordUUID: String?) {
        guard !movers.isEmpty else { return }
        let expected = regroupLocally(movers, joining: coordUUID)
        let generation = nextRegroupGeneration()
        let send: () async -> Void = { [weak self] in
            guard let self else { return }
            if let coordUUID {
                await self.join(movers, to: coordUUID)
            } else {
                await self.standalone(movers)
            }
        }
        Task {
            await send()
            await settleTopology(expecting: expected, generation: generation, resend: send)
        }
    }

    /// All members of `sourceID` join the group of `targetID` (target keeps its audio).
    func merge(_ sourceID: String, into targetID: String) {
        guard let source = groups.first(where: { $0.id == sourceID }),
              let target = groups.first(where: { $0.id == targetID }) else { return }
        regroup(source.members, joining: target.coordinatorUUID)
    }

    /// Pulls one speaker out. Never called for a coordinator — sending a
    /// coordinator away from its own group strands the speakers left behind
    /// with no source, which reads as "grouping broke playback".
    func removeFromGroup(_ member: SonosSpeaker) {
        // By UUID, not by value: SonosSpeaker's equality includes its volume,
        // so a level arriving between render and tap would make this miss.
        guard let g = groups.first(where: { g in
            g.members.contains { $0.uuid == member.uuid }
        }), g.coordinatorUUID != member.uuid else { return }
        regroup([member], joining: nil)
    }

    func separate(_ id: String) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        regroup(g.members.filter { $0.uuid != g.coordinatorUUID }, joining: nil)
    }

    /// Party mode: everything joins one group (a playing group wins as anchor).
    func groupAll() {
        guard groups.count > 1 else { return }
        let anchor = groups.first(where: { $0.transportState == .playing })
            ?? groups.max(by: { $0.members.count < $1.members.count })!
        regroup(groups.filter { $0.id != anchor.id }.flatMap(\.members),
                joining: anchor.coordinatorUUID)
    }

    func separateAll() {
        regroup(groups.filter { $0.members.count > 1 }
            .flatMap { g in g.members.filter { $0.uuid != g.coordinatorUUID } },
                joining: nil)
    }

    // MARK: Misc

    func setExpanded(_ key: String, _ expanded: Bool) {
        if expanded {
            expandedGroups.insert(key)
            Task { await refreshMemberVolumes(key) }
        } else {
            expandedGroups.remove(key)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

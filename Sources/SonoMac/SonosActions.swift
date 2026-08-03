import Foundation
import AppKit

// MARK: - User actions

extension SonosSystem {

    // MARK: Volume

    func setGroupVolume(_ id: String, _ value: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let v = max(0, min(100, value))
        groups[i].volume = v
        suppress("v:\(id)")
        for m in groups[i].members { suppress("m:\(m.uuid)") }
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
        let ip = groups[gi].members[mi].ip
        throttler("mv:\(uuid)").call {
            await Self.setPlayerVolume(ip, v)
        }
    }

    func masterEditing(_ editing: Bool) {
        if editing {
            masterBase = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.volume) })
            masterStart = masterVolume
        } else {
            masterBase = nil
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
        Task {
            _ = try? await SOAP.call(.groupRenderingControl, action: "SetGroupMute",
                                     args: [("InstanceID", "0"), ("DesiredMute", target ? "1" : "0")],
                                     host: ip)
        }
    }

    func toggleMuteAll() {
        let target = !allMuted
        for i in groups.indices {
            groups[i].muted = target
            suppress("v:\(groups[i].id)")
            let ip = groups[i].coordinator.ip
            Task {
                _ = try? await SOAP.call(.groupRenderingControl, action: "SetGroupMute",
                                         args: [("InstanceID", "0"), ("DesiredMute", target ? "1" : "0")],
                                         host: ip)
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
        Task {
            if wasPlaying {
                _ = try? await SOAP.call(.avTransport, action: "Pause",
                                         args: [("InstanceID", "0")], host: ip)
            } else {
                _ = try? await SOAP.call(.avTransport, action: "Play",
                                         args: [("InstanceID", "0"), ("Speed", "1")], host: ip)
            }
        }
    }

    func next(_ id: String) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        Task {
            _ = try? await SOAP.call(.avTransport, action: "Next",
                                     args: [("InstanceID", "0")], host: g.coordinator.ip)
        }
    }

    func previous(_ id: String) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        Task {
            _ = try? await SOAP.call(.avTransport, action: "Previous",
                                     args: [("InstanceID", "0")], host: g.coordinator.ip)
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
        Task {
            await withTaskGroup(of: Void.self) { tg in
                for m in members {
                    tg.addTask { await Self.setPlayerVolume(m.ip, target) }
                }
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
        Task {
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

    /// All members of `sourceID` join the group of `targetID` (target keeps its audio).
    func merge(_ sourceID: String, into targetID: String) {
        guard let source = groups.first(where: { $0.id == sourceID }),
              let target = groups.first(where: { $0.id == targetID }) else { return }
        let members = source.members
        let coordUUID = target.coordinatorUUID
        Task {
            for m in members {
                _ = try? await SOAP.call(.avTransport, action: "SetAVTransportURI",
                                         args: [("InstanceID", "0"),
                                                ("CurrentURI", "x-rincon:\(coordUUID)"),
                                                ("CurrentURIMetaData", "")],
                                         host: m.ip)
            }
            await refreshTopologyQuiet()
            await refreshState()
        }
    }

    func removeFromGroup(_ member: SonosSpeaker) {
        Task {
            _ = try? await SOAP.call(.avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                                     args: [("InstanceID", "0")], host: member.ip)
            await refreshTopologyQuiet()
            await refreshState()
        }
    }

    func separate(_ id: String) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        let others = g.members.filter { $0.uuid != g.coordinatorUUID }
        Task {
            for m in others {
                _ = try? await SOAP.call(.avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                                         args: [("InstanceID", "0")], host: m.ip)
            }
            await refreshTopologyQuiet()
            await refreshState()
        }
    }

    /// Party mode: everything joins one group (a playing group wins as anchor).
    func groupAll() {
        guard groups.count > 1 else { return }
        let anchor = groups.first(where: { $0.transportState == .playing })
            ?? groups.max(by: { $0.members.count < $1.members.count })!
        let joiners = groups.filter { $0.id != anchor.id }.flatMap(\.members)
        let coordUUID = anchor.coordinatorUUID
        Task {
            for m in joiners {
                _ = try? await SOAP.call(.avTransport, action: "SetAVTransportURI",
                                         args: [("InstanceID", "0"),
                                                ("CurrentURI", "x-rincon:\(coordUUID)"),
                                                ("CurrentURIMetaData", "")],
                                         host: m.ip)
            }
            await refreshTopologyQuiet()
            await refreshState()
        }
    }

    func separateAll() {
        let members = groups.filter { $0.members.count > 1 }
            .flatMap { g in g.members.filter { $0.uuid != g.coordinatorUUID } }
        guard !members.isEmpty else { return }
        Task {
            for m in members {
                _ = try? await SOAP.call(.avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                                         args: [("InstanceID", "0")], host: m.ip)
            }
            await refreshTopologyQuiet()
            await refreshState()
        }
    }

    // MARK: Misc

    func setExpanded(_ id: String, _ expanded: Bool) {
        if expanded {
            expandedGroups.insert(id)
            Task { await refreshMemberVolumes(id) }
        } else {
            expandedGroups.remove(id)
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

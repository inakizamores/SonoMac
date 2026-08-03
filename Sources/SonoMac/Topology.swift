import Foundation

/// Parses the ZoneGroupState XML returned by ZoneGroupTopology#GetZoneGroupState.
final class TopologyParser: NSObject, XMLParserDelegate {
    private var groups: [SonosGroup] = []
    private var currentGroupID = ""
    private var currentCoordinator = ""
    private var currentMembers: [SonosSpeaker] = []

    static func parse(_ xml: String) -> [SonosGroup] {
        let p = TopologyParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()
        return p.groups
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attr: [String: String] = [:]) {
        switch elementName {
        case "ZoneGroup":
            currentGroupID = attr["ID"] ?? ""
            currentCoordinator = attr["Coordinator"] ?? ""
            currentMembers = []
        case "ZoneGroupMember":
            // Skip bonded/invisible players (stereo-pair right, surrounds, subs, Boost).
            guard attr["Invisible"] != "1", attr["IsZoneBridge"] != "1",
                  let uuid = attr["UUID"],
                  let location = attr["Location"],
                  let host = URLComponents(string: location)?.host,
                  let name = attr["ZoneName"], !name.isEmpty
            else { return }
            currentMembers.append(SonosSpeaker(uuid: uuid, name: name, ip: host))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "ZoneGroup", !currentMembers.isEmpty else { return }
        let coord = currentCoordinator
        currentMembers.sort { a, b in
            if a.uuid == coord { return true }
            if b.uuid == coord { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        groups.append(SonosGroup(id: currentGroupID,
                                 coordinatorUUID: coord,
                                 members: currentMembers))
    }
}

import Foundation

enum SonosService {
    case avTransport, renderingControl, groupRenderingControl, zoneGroupTopology

    var path: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        }
    }

    var urn: String {
        switch self {
        case .avTransport: return "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: return "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: return "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .zoneGroupTopology: return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        }
    }
}

enum SonosError: Error {
    case http(Int), badResponse
}

enum SOAP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 6
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// `retry` is for commands, not reads. A busy speaker drops the odd
    /// connection, and a silently swallowed command is what leaves the panel
    /// describing a state the system never actually reached. Reads stay
    /// single-shot on purpose: retrying them would double every poll's
    /// latency against a speaker that is simply gone.
    @discardableResult
    static func call(_ service: SonosService,
                     action: String,
                     args: [(String, String)] = [],
                     host ip: String,
                     retry: Bool = false) async throws -> String {
        do {
            return try await send(service, action: action, args: args, host: ip)
        } catch let error as URLError where retry && isTransient(error) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return try await send(service, action: action, args: args, host: ip)
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .cannotFindHost, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func send(_ service: SonosService,
                             action: String,
                             args: [(String, String)],
                             host ip: String) async throws -> String {
        var body = ""
        for (k, v) in args { body += "<\(k)>\(xmlEscape(v))</\(k)>" }
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(body)</u:\(action)></s:Body></s:Envelope>"

        var req = URLRequest(url: URL(string: "http://\(ip):1400\(service.path)")!)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = envelope.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SonosError.badResponse }
        guard http.statusCode == 200 else { throw SonosError.http(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw SonosError.badResponse }
        return text
    }

    /// Extracts the raw text between <tag> and </tag> (no unescaping).
    static func value(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func xmlEscape(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&apos;")
        return r
    }

    static func xmlUnescape(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&lt;", with: "<")
        r = r.replacingOccurrences(of: "&gt;", with: ">")
        r = r.replacingOccurrences(of: "&quot;", with: "\"")
        r = r.replacingOccurrences(of: "&apos;", with: "'")
        r = r.replacingOccurrences(of: "&amp;", with: "&")
        return r
    }
}

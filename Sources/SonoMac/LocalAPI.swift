import Foundation

/// The speakers' own JSON API on port 1443 — what the Sonos app talks to
/// locally. UPnP has no word on stream quality; this does: each track carries
/// bit depth, sample rate, and whether it's lossless or immersive (Atmos).
enum LocalAPI {
    /// The key every local client of this API sends; the speakers accept it
    /// without any account sign-in.
    private static let apiKey = "123e4567-e89b-12d3-a456-426655440000"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: SpeakerTrust(), delegateQueue: nil)
    }()

    /// "Lossless 16/44.1", "Hi-Res 24/96", "Dolby Atmos" for the group's
    /// current track; nil for lossy streams or when the speaker doesn't say.
    static func trackFormat(group id: String, ip: String) async -> String? {
        let path = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "https://\(ip):1443/api/v1/groups/\(path)/playbackMetadata")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let meta = try? JSONDecoder().decode(Metadata.self, from: data),
              let q = meta.currentItem?.track?.quality
        else { return nil }
        return TrackQuality.label(bitDepth: q.bitDepth, sampleRate: q.sampleRate,
                                  lossless: q.lossless, immersive: q.immersive)
    }

    private struct Metadata: Decodable {
        struct Item: Decodable { let track: Track? }
        struct Track: Decodable { let quality: Quality? }
        struct Quality: Decodable {
            let bitDepth: Int?
            let sampleRate: Int?
            let lossless: Bool?
            let immersive: Bool?
        }
        let currentItem: Item?
    }
}

/// Each speaker serves this API with its own self-signed certificate, so
/// standard validation always fails. Trust is scoped to that one port on a
/// private address — nothing else this app fetches goes through here.
private final class SpeakerTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.port == 1443, Self.isPrivate(space.host),
              let trust = space.serverTrust
        else { return completionHandler(.performDefaultHandling, nil) }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func isPrivate(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168)
            || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }
}

enum TrackQuality {
    static func label(bitDepth: Int?, sampleRate: Int?,
                      lossless: Bool?, immersive: Bool?) -> String? {
        if immersive == true { return "Dolby Atmos" }
        // Lossy streams report nominal 16/44.1 too (Spotify does); quoting
        // those numbers would imply a quality the stream doesn't have.
        guard lossless == true else { return nil }
        guard let bits = bitDepth, let rate = sampleRate, bits > 0, rate > 0 else {
            return "Lossless"
        }
        let hiRes = bits > 16 || rate > 48_000
        return "\(hiRes ? "Hi-Res" : "Lossless") \(bits)/\(kHz(rate))"
    }

    /// 44100 → "44.1", 48000 → "48", 96000 → "96".
    private static func kHz(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000)" : String(format: "%.1f", Double(rate) / 1000)
    }
}

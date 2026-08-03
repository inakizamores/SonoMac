import Foundation
import Darwin

/// SSDP discovery for Sonos players (urn:schemas-upnp-org:device:ZonePlayer:1).
enum SSDP {
    static func discover(timeout: TimeInterval = 2.0) async -> Set<String> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: search(timeout: timeout))
            }
        }
    }

    private static func search(timeout: TimeInterval) -> Set<String> {
        var ips = Set<String>()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return ips }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let msg = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 1\r\n"
            + "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        let payload = Array(msg.utf8)

        for _ in 0..<3 {
            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            guard text.localizedCaseInsensitiveContains("Sonos")
                || text.contains("ZonePlayer") else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = from.sin_addr
            if inet_ntop(AF_INET, &sin, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                ips.insert(String(cString: ipBuf))
            }
        }
        return ips
    }
}

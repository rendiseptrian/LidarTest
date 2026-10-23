import Foundation
import Network

nonisolated public struct NetworkUtils {
    /// Must match `NSBonjourServices` in the iOS target's build settings, or iOS refuses to advertise it.
    public static let bonjourServiceType = "_lidar-stream._tcp"
    public static let defaultPort: UInt16 = 8088

    /// Shared TCP tuning for both ends of the mesh stream.
    ///
    /// Keepalive gives up after ~40 s of silence (10 s idle + 6 × 5 s probes). The previous 2/1/5
    /// setting killed the socket after ~7 s, which a Wi-Fi access-point handoff while walking a
    /// large room routinely exceeds. Liveness is also checked at the app level via heartbeats.
    public static func makeTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 6

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        // Bulk mesh transfer, not latency-critical video.
        params.serviceClass = .responsiveData
        return params
    }

    /// Returns the active local IPv4 address (Wi-Fi or Ethernet)
    public static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 is typically Wi-Fi on iOS and primary Wi-Fi/Ethernet on Mac
                if name == "en0" || name == "en1" || name == "pdp_ip0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        address = String(cString: hostname)
                        if name == "en0" {
                            break // Prefer en0
                        }
                    }
                }
            }
        }

        return address
    }
}

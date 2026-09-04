import Foundation
import Network

/// The three always on checks: default gateway, DNS, and a known good HTTPS
/// target. Together they tell the verdict engine whether "me" is the problem.
protocol BaselineProbing: Sendable {
    func run(internetURL: URL, dnsHost: String) async -> BaselineResult
}

struct BaselineProber: BaselineProbing {
    static let gatewayTimeout: TimeInterval = 4

    let http: HTTPFetching

    func run(internetURL: URL, dnsHost: String) async -> BaselineResult {
        async let gateway = Self.probeGateway()
        async let dns = DNSProbe.run(host: dnsHost, resolver: nil, spec: .dns(host: dnsHost, resolver: nil), timeout: ProbeRunner.timeout)
        async let internet = HTTPSHeadProbe.run(url: internetURL, spec: .httpsHead(url: internetURL), http: http)
        return BaselineResult(gateway: await gateway, dns: await dns, internet: await internet, checkedAt: Date())
    }

    /// TCP to the default gateway. Routers rarely listen on port 80 for the
    /// LAN side, but a refused connection is still an answer from the
    /// gateway, so it counts as reachable. Only a timeout or "no route" fails.
    static func probeGateway() async -> ProbeResult {
        guard let gateway = DefaultRoute.gatewayAddress() else {
            return ProbeResult(spec: .tcp(host: "gateway", port: 80), ok: false, latency: nil, detail: "No default route")
        }
        let spec = ProbeSpec.tcp(host: gateway, port: 80)
        return await TCPProbe.run(host: gateway, port: 80, spec: spec, timeout: gatewayTimeout, refusedCountsAsUp: true)
    }
}

/// Reads the IPv4 default route from the kernel routing table via sysctl.
/// No subprocess, no private API, works inside the App Sandbox.
enum DefaultRoute {
    static func gatewayAddress() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self).pointee
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }
                guard header.rtm_flags & RTF_GATEWAY != 0, header.rtm_addrs & RTA_DST != 0, header.rtm_addrs & RTA_GATEWAY != 0 else { continue }

                var cursor = offset + MemoryLayout<rt_msghdr>.size
                var destination: sockaddr_in?
                var gateway: sockaddr_in?
                for bit in 0..<RTAX_MAX {
                    guard header.rtm_addrs & (1 << bit) != 0 else { continue }
                    guard cursor + MemoryLayout<sockaddr>.size <= offset + messageLength else { break }
                    let sa = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr.self).pointee
                    let saLength = Int(sa.sa_len)
                    if sa.sa_family == UInt8(AF_INET), saLength >= MemoryLayout<sockaddr_in>.size {
                        let sin = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr_in.self).pointee
                        if bit == RTAX_DST { destination = sin }
                        if bit == RTAX_GATEWAY { gateway = sin }
                    }
                    // Addresses are rounded up to a 4 byte boundary; a zero length means 4.
                    cursor += saLength == 0 ? 4 : (saLength + 3) & ~3
                }
                if let destination, destination.sin_addr.s_addr == 0, let gateway {
                    var addr = gateway.sin_addr
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                    return String(cString: text)
                }
            }
            return nil
        }
    }
}

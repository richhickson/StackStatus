import Foundation
import Network

/// Runs probes. Injected into the scheduler so tests can substitute a fake.
protocol Prober: Sendable {
    func run(_ spec: ProbeSpec) async -> ProbeResult
}

/// Dispatches each probe type to its implementation.
struct ProbeRunner: Prober {
    static let timeout: TimeInterval = 10

    let http: HTTPFetching

    func run(_ spec: ProbeSpec) async -> ProbeResult {
        switch spec {
        case .httpsHead(let url):
            return await HTTPSHeadProbe.run(url: url, spec: spec, http: http)
        case .tcp(let host, let port):
            return await TCPProbe.run(host: host, port: port, spec: spec, timeout: Self.timeout, refusedCountsAsUp: false)
        case .dns(let host, let resolver):
            return await DNSProbe.run(host: host, resolver: resolver, spec: spec, timeout: Self.timeout)
        }
    }
}

/// HEAD request. Any HTTP response below 500 proves the host is up, so a 401
/// or 403 from an API host is a pass.
enum HTTPSHeadProbe {
    static func run(url: URL, spec: ProbeSpec, http: HTTPFetching) async -> ProbeResult {
        do {
            let (status, latency) = try await http.head(url)
            return ProbeResult(spec: spec, ok: status < 500, latency: latency, detail: "HTTP \(status)")
        } catch {
            return ProbeResult(spec: spec, ok: false, latency: nil, detail: String(describing: error))
        }
    }
}

/// TCP connect using Network.framework. A refused connection still proves the
/// host is reachable at the network layer, which is what the gateway check
/// wants; vendor probes want the port to actually accept.
enum TCPProbe {
    enum Outcome: Sendable {
        case connected(TimeInterval)
        case refused(TimeInterval)
        case failed(String)
        case timedOut
    }

    static func run(host: String, port: Int, spec: ProbeSpec, timeout: TimeInterval, refusedCountsAsUp: Bool) async -> ProbeResult {
        let outcome = await connect(host: host, port: port, timeout: timeout)
        switch outcome {
        case .connected(let latency):
            return ProbeResult(spec: spec, ok: true, latency: latency, detail: "Connected")
        case .refused(let latency):
            return ProbeResult(spec: spec, ok: refusedCountsAsUp, latency: latency, detail: "Connection refused")
        case .failed(let message):
            return ProbeResult(spec: spec, ok: false, latency: nil, detail: message)
        case .timedOut:
            return ProbeResult(spec: spec, ok: false, latency: nil, detail: "Timed out")
        }
    }

    static func connect(host: String, port: Int, timeout: TimeInterval) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed("Bad port") }
        let started = Date()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let queue = DispatchQueue(label: "com.helpfullyit.stackstatus.tcpprobe")
        let box = ContinuationBox<Outcome>()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.store(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(.connected(Date().timeIntervalSince(started)))
                        connection.cancel()
                    case .failed(let error):
                        if case .posix(let code) = error, code == .ECONNREFUSED {
                            box.resume(.refused(Date().timeIntervalSince(started)))
                        } else {
                            box.resume(.failed(error.localizedDescription))
                        }
                        connection.cancel()
                    case .waiting(let error):
                        // No route or no network: do not sit here until the timeout.
                        if case .posix(let code) = error, code == .ENETUNREACH || code == .EHOSTUNREACH || code == .ENETDOWN {
                            box.resume(.failed(error.localizedDescription))
                            connection.cancel()
                        }
                    case .cancelled:
                        box.resume(.failed("Cancelled"))
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    box.resume(.timedOut)
                    connection.cancel()
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            box.resume(.failed("Cancelled"))
            connection.cancel()
        }
    }
}

/// DNS resolution. Without a resolver the system resolver is used. With one,
/// a minimal A query is sent straight to that server over UDP.
enum DNSProbe {
    static func run(host: String, resolver: String?, spec: ProbeSpec, timeout: TimeInterval) async -> ProbeResult {
        let started = Date()
        if let resolver {
            let outcome = await query(host: host, resolver: resolver, timeout: timeout)
            switch outcome {
            case .success(let answers):
                return ProbeResult(spec: spec, ok: true, latency: Date().timeIntervalSince(started), detail: "\(answers) answer\(answers == 1 ? "" : "s")")
            case .failure(let error):
                return ProbeResult(spec: spec, ok: false, latency: nil, detail: error.message)
            }
        }
        let outcome = await resolveWithSystem(host: host, timeout: timeout)
        switch outcome {
        case .success(let count):
            return ProbeResult(spec: spec, ok: true, latency: Date().timeIntervalSince(started), detail: "\(count) address\(count == 1 ? "" : "es")")
        case .failure(let error):
            return ProbeResult(spec: spec, ok: false, latency: nil, detail: error.message)
        }
    }

    struct Failure: Error, Sendable { var message: String }

    /// getaddrinfo on a background thread, raced against the timeout.
    static func resolveWithSystem(host: String, timeout: TimeInterval) async -> Result<Int, Failure> {
        await withTaskGroup(of: Result<Int, Failure>?.self) { group in
            group.addTask {
                await Task.detached(priority: .utility) { () -> Result<Int, Failure> in
                    var hints = addrinfo()
                    hints.ai_family = AF_UNSPEC
                    hints.ai_socktype = SOCK_STREAM
                    var result: UnsafeMutablePointer<addrinfo>?
                    let status = getaddrinfo(host, nil, &hints, &result)
                    defer { if let result { freeaddrinfo(result) } }
                    guard status == 0 else {
                        return .failure(Failure(message: String(cString: gai_strerror(status))))
                    }
                    var count = 0
                    var cursor = result
                    while let node = cursor {
                        count += 1
                        cursor = node.pointee.ai_next
                    }
                    return .success(count)
                }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(Failure(message: "Timed out"))
        }
    }

    /// Send one A query to a specific resolver over UDP and count the answers.
    static func query(host: String, resolver: String, timeout: TimeInterval) async -> Result<Int, Failure> {
        let id = UInt16.random(in: 1...UInt16.max)
        let packet = buildQuery(id: id, name: host)
        let connection = NWConnection(host: NWEndpoint.Host(resolver), port: 53, using: .udp)
        let queue = DispatchQueue(label: "com.helpfullyit.stackstatus.dnsprobe")
        let box = ContinuationBox<Result<Int, Failure>>()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.store(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: packet, completion: .contentProcessed { error in
                            if let error {
                                box.resume(.failure(Failure(message: error.localizedDescription)))
                                connection.cancel()
                            }
                        })
                        connection.receiveMessage { data, _, _, error in
                            if let error {
                                box.resume(.failure(Failure(message: error.localizedDescription)))
                            } else if let data {
                                box.resume(parseAnswer(data, expectedID: id))
                            } else {
                                box.resume(.failure(Failure(message: "Empty reply")))
                            }
                            connection.cancel()
                        }
                    case .failed(let error):
                        box.resume(.failure(Failure(message: error.localizedDescription)))
                        connection.cancel()
                    case .waiting(let error):
                        if case .posix(let code) = error, code == .ENETUNREACH || code == .EHOSTUNREACH || code == .ENETDOWN {
                            box.resume(.failure(Failure(message: error.localizedDescription)))
                            connection.cancel()
                        }
                    case .cancelled:
                        box.resume(.failure(Failure(message: "Cancelled")))
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    box.resume(.failure(Failure(message: "Timed out")))
                    connection.cancel()
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            box.resume(.failure(Failure(message: "Cancelled")))
            connection.cancel()
        }
    }

    /// Standard query: header, one question, no EDNS.
    static func buildQuery(id: UInt16, name: String) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xff)])
        data.append(contentsOf: [0x01, 0x00])            // flags: recursion desired
        data.append(contentsOf: [0x00, 0x01])            // QDCOUNT 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".") where !label.isEmpty {
            let bytes = Array(label.utf8.prefix(63))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        data.append(contentsOf: [0x00, 0x01])            // QTYPE A
        data.append(contentsOf: [0x00, 0x01])            // QCLASS IN
        return data
    }

    /// Accepts a reply when the ID matches, it is a response, RCODE is 0 and
    /// there is at least one answer record.
    static func parseAnswer(_ data: Data, expectedID: UInt16) -> Result<Int, Failure> {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return .failure(Failure(message: "Short reply")) }
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard id == expectedID else { return .failure(Failure(message: "ID mismatch")) }
        guard bytes[2] & 0x80 != 0 else { return .failure(Failure(message: "Not a response")) }
        let rcode = bytes[3] & 0x0f
        guard rcode == 0 else { return .failure(Failure(message: "RCODE \(rcode)")) }
        let answers = Int(bytes[6]) << 8 | Int(bytes[7])
        guard answers > 0 else { return .failure(Failure(message: "No answers")) }
        return .success(answers)
    }
}

/// Resumes a continuation exactly once, from whichever callback wins.
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func store(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

//
//  DashSocket.swift
//  ReTripper
//
//  UDP transport to the Tripper Dash. A single BSD POSIX socket bound to
//  the local RX port (:2002) with `sendto` going to the dash (:2000). We
//  can't use NWConnection: on UDP it filters inbound datagrams by the peer
//  endpoint, and the dash replies from a different port than we send to, so
//  every reply would be dropped.
//
//  Based on TripperDash++ (DashSocket) by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import Foundation
import Darwin

actor DashSocket {

    nonisolated let inbound: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let host: String
    private let port: UInt16
    private let localPort: UInt16
    private var fd: Int32 = -1
    private var dest = sockaddr_in()
    private var readSource: DispatchSourceRead?
    private let ioQueue: DispatchQueue

    private nonisolated static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
    private var lastRxUptime = DashSocket.now()
    func secondsSinceLastRx() -> TimeInterval { DashSocket.now() - lastRxUptime }

    init(host: String = K1G.bikeIPv4, port: UInt16 = K1G.txPort, localPort: UInt16 = K1G.rxPort) {
        self.host = host
        self.port = port
        self.localPort = localPort
        self.ioQueue = DispatchQueue(label: "DashSocket.io.\(localPort)", qos: .userInitiated)
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream(bufferingPolicy: .unbounded) { c in cont = c }
        self.inboundContinuation = cont
    }

    deinit { readSource?.cancel() }

    /// Create + bind the socket and arm inbound reading. UDP has no ready
    /// handshake, so this returns as soon as the socket is live.
    func start() throws {
        guard fd < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if s < 0 { throw err("socket(): \(errnoText())") }

        var on: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_addr.s_addr = INADDR_ANY.bigEndian
        bindAddr.sin_port = localPort.bigEndian
        let bound = withUnsafePointer(to: &bindAddr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 { let e = errnoText(); close(s); throw err("bind(:\(localPort)): \(e)") }

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &destAddr.sin_addr) != 1 {
            let e = errnoText(); close(s); throw err("inet_pton(\(host)): \(e)")
        }
        self.dest = destAddr

        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.drainAllPending() }
        src.setCancelHandler { close(s) }
        src.resume()

        self.fd = s
        self.readSource = src
    }

    func send(_ data: Data) async throws {
        guard fd >= 0 else { throw err("send() before start()/after cancel()") }
        let fdCopy = fd
        var destCopy = dest
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                let sent = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ssize_t in
                    guard let base = raw.baseAddress else { return -1 }
                    return withUnsafePointer(to: &destCopy) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fdCopy, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if sent < 0 {
                    let code = errno
                    cont.resume(throwing: NSError(domain: "DashSocket", code: Int(code),
                        userInfo: [NSLocalizedDescriptionKey: "sendto(): \(String(cString: strerror(code)))"]))
                } else if sent != data.count {
                    cont.resume(throwing: NSError(domain: "DashSocket", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "short write \(sent)/\(data.count)"]))
                } else {
                    cont.resume()
                }
            }
        }
    }

    func cancel() {
        guard let src = readSource else { return }
        readSource = nil
        fd = -1
        inboundContinuation.finish()
        src.cancel()
    }

    // MARK: - Inbound

    private nonisolated func drainAllPending() {
        Task { await self.drain() }
    }
    private func drain() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                lastRxUptime = DashSocket.now()
                inboundContinuation.yield(Data(buf[0..<n]))
            } else { break }
        }
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "DashSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func errnoText() -> String { String(cString: strerror(errno)) }
}

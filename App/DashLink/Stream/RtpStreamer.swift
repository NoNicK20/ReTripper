//
//  RtpStreamer.swift
//  ReTripper
//
//  Orchestrates the video pipeline:
//    FrameSource → H264Encoder → RtpPacketizer → UDP socket on dash:5000
//
//  `onFrameKick` fires once per coded frame so the owner can send the K1G
//  PROJ_FRAME TLV; `onStreamFailed` reports a transport failure.
//
//  Based on TripperDash++ (RtpStreamer) by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import Foundation
import Network
import CoreMedia
import os.log

struct RtpStreamerMetrics: Sendable, Equatable {
    var encodedFps: Double = 0
    var kbpsOut: Double = 0
    var packetsSent: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var nalsEmitted: UInt64 = 0
    var idrCount: UInt64 = 0
    var lastError: String?
}

@MainActor
final class RtpStreamer {

    enum State: String, Sendable { case idle, starting, running, stopping, failed }

    private let bikeHost: String
    private let bikePort: UInt16
    private let source: FrameSource
    private let encoder: H264Encoder
    private let pipe = RtpSendPipe(packetizer: RtpPacketizer(),
                                  timestampBase: UInt32.random(in: 0..<UInt32.max))

    /// Fires once per coded frame (owner sends PROJ_FRAME).
    var onFrameKick: (() -> Void)?
    /// Fires on a transport failure the owner should react to.
    var onStreamFailed: (() -> Void)?

    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "com.nonick20.retripper.rtp.send", qos: .userInitiated)

    private(set) var state: State = .idle
    private(set) var metrics = RtpStreamerMetrics()
    var onMetrics: ((RtpStreamerMetrics) -> Void)?

    private var lastTickAt = Date()
    private var metricsTimer: Timer?
    private let log = Logger(subsystem: "com.nonick20.retripper", category: "RtpStreamer")

    init(bikeHost: String = K1G.bikeIPv4, bikePort: UInt16 = K1G.rtpPort, source: FrameSource) {
        self.bikeHost = bikeHost
        self.bikePort = bikePort
        self.source = source
        self.encoder = H264Encoder(width: Int32(source.frameSize.width),
                                   height: Int32(source.frameSize.height),
                                   fps: Int32(source.targetFps))
    }

    deinit {
        pipe.end()
        connection?.cancel()
    }

    func start() {
        guard state == .idle || state == .failed else { return }
        state = .starting
        metrics = RtpStreamerMetrics()

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(bikeHost),
                                           port: NWEndpoint.Port(integerLiteral: bikePort))
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { [weak self] s in
            Task { @MainActor [weak self] in self?.handleConnectionState(s) }
        }
        conn.start(queue: sendQueue)
        self.connection = conn

        pipe.begin(connection: conn, onFrame: { [weak self] in
            Task { @MainActor [weak self] in self?.onFrameKick?() }
        })
        lastTickAt = Date()
        let pipe = self.pipe
        let queue = sendQueue
        encoder.onNAL = { @Sendable nal in queue.async { pipe.handle(nal) } }
        do {
            try encoder.start()
        } catch {
            fail(reason: "Encoder start failed: \(error)")
            return
        }

        source.start { [weak self] pixelBuffer, pts in
            self?.encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
        }
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushMetrics() }
        }
        state = .running
    }

    func stop() {
        guard state == .running || state == .starting else { return }
        state = .stopping
        metricsTimer?.invalidate(); metricsTimer = nil
        source.stop()
        encoder.stop()
        pipe.end()
        connection?.cancel(); connection = nil
        state = .idle
    }

    private func handleConnectionState(_ s: NWConnection.State) {
        switch s {
        case .ready:
            log.info("RTP UDP ready (\(self.bikeHost, privacy: .public):\(self.bikePort))")
        case .failed(let err):
            if state != .idle { onStreamFailed?() }
            fail(reason: "UDP failed: \(err.localizedDescription)")
        case .waiting(let err):
            log.warning("RTP UDP waiting: \(err.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    private func fail(reason: String) {
        log.error("\(reason, privacy: .public)")
        metrics.lastError = reason
        onMetrics?(metrics)
        stop()
        state = .failed
    }

    private func flushMetrics() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTickAt), 0.001)
        let c = pipe.takeWindow()
        metrics.encodedFps = Double(c.windowNALs) / dt
        metrics.kbpsOut = Double(c.windowBytes * 8) / dt / 1000.0
        metrics.packetsSent = c.packetsSent
        metrics.packetsDropped = c.packetsDropped
        metrics.nalsEmitted = c.nalsEmitted
        metrics.idrCount = c.idrCount
        lastTickAt = now
        onMetrics?(metrics)
    }
}

/// Encoded NAL → RTP datagrams → UDP, entirely on the streamer's send
/// queue. Counters sit behind a lock; the main actor reads them at 1 Hz.
final class RtpSendPipe: @unchecked Sendable {

    struct Counters: Sendable {
        var windowNALs: UInt64 = 0
        var windowBytes: UInt64 = 0
        var packetsSent: UInt64 = 0
        var packetsDropped: UInt64 = 0
        var nalsEmitted: UInt64 = 0
        var idrCount: UInt64 = 0
    }

    private let packetizer: RtpPacketizer
    private let timestampBase: UInt32
    private let lock = NSLock()
    private var connection: NWConnection?
    private var onFrame: (@Sendable () -> Void)?
    private var counters = Counters()
    private var failedRun: UInt64 = 0

    init(packetizer: RtpPacketizer, timestampBase: UInt32) {
        self.packetizer = packetizer
        self.timestampBase = timestampBase
    }

    func begin(connection: NWConnection, onFrame: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.connection = connection
            self.onFrame = onFrame
            counters = Counters()
        }
    }

    func end() {
        lock.withLock { connection = nil; onFrame = nil }
    }

    func takeWindow() -> Counters {
        lock.withLock {
            let snapshot = counters
            counters.windowNALs = 0
            counters.windowBytes = 0
            return snapshot
        }
    }

    func handle(_ nal: EncodedNAL) {
        let ptsSeconds = CMTimeGetSeconds(nal.timestamp)
        let rtpTs = timestampBase &+ UInt32(truncatingIfNeeded: Int64(ptsSeconds * 90_000))
        let markerOnLast: Bool
        let isFrame: Bool
        let isIDR: Bool
        switch nal.kind {
        case .idr: markerOnLast = true; isFrame = true; isIDR = true
        case .nonIDR: markerOnLast = true; isFrame = true; isIDR = false
        default: markerOnLast = false; isFrame = false; isIDR = false
        }
        let datagrams = packetizer.packetize(nal: nal.bytes, timestamp90kHz: rtpTs, markerOnLast: markerOnLast)
        let link: (connection: NWConnection?, onFrame: (@Sendable () -> Void)?) = lock.withLock {
            counters.windowNALs += 1
            if isIDR { counters.idrCount += 1 }
            counters.nalsEmitted += 1
            return (connection: connection, onFrame: onFrame)
        }
        for datagram in datagrams { send(datagram, on: link.connection) }
        if isFrame { link.onFrame?() }
    }

    private func send(_ datagram: RtpDatagram, on connection: NWConnection?) {
        guard let connection else {
            lock.withLock { counters.packetsDropped += 1 }
            return
        }
        lock.withLock { counters.windowBytes += UInt64(datagram.bytes.count) }
        connection.send(content: datagram.bytes, completion: .contentProcessed { err in
            self.lock.withLock {
                if err != nil { self.counters.packetsDropped += 1; self.failedRun += 1 }
                else { self.counters.packetsSent += 1; self.failedRun = 0 }
            }
        })
    }
}

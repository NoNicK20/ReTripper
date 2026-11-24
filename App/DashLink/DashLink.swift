//
//  DashLink.swift
//  ReTripper
//
//  Orchestrates a Tripper Dash control-plane session over the dash's Wi-Fi:
//
//    open UDP socket → send the initial burst → receive the RSA modulus +
//    exponent → send the encrypted session key → receive auth-OK → start the
//    1 Hz heartbeat → connected.
//
//  This is what makes the dash show "device connected". Projecting the map
//  (H.264/RTP video + nav TLVs) is a later phase and builds on this link.
//
//  Protocol/transport based on TripperDash++ by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//
//  NOTE: the live socket, handshake and heartbeat can only be verified
//  against a real bike. The byte-level encoders/decoders are unit-tested.
//

import Foundation
import Combine
import os
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class DashLink: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case handshaking
        case connected
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastMessage: String?

    /// A generic hostname shown on the dash's pairing screen. Deliberately
    /// NOT the user's device name — that would leak personal information.
    var hostname = "ReTripper"

    private let log = Logger(subsystem: "com.nonick20.retripper", category: "DashLink")
    private let seq = RollingSeq()
    private var socket: DashSocket?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    // Accumulated inbound segments + a single pending waiter.
    private var received: [K1GSegment] = []
    private var waiter: (id: Int, check: ([K1GSegment]) -> Bool, resume: (Bool) -> Void)?
    private var waiterCounter = 0

    // MARK: - API

    /// Establish a dash session. The phone must already be on the dash Wi-Fi.
    func connect(ssid: String) {
        guard connectTask == nil else { return }
        state = .connecting
        lastMessage = "Opening a connection to the dashboard…"
        connectTask = Task { await self.runConnect(ssid: ssid) }
    }

    func disconnect() {
        connectTask?.cancel(); connectTask = nil
        teardown()
        state = .idle
        lastMessage = "Disconnected from the dashboard."
    }

    // MARK: - Connect flow (with boot-race retries)

    private func runConnect(ssid: String) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                try await attemptHandshake(ssid: ssid)
                connectTask = nil
                return
            } catch is CancellationError {
                connectTask = nil
                return
            } catch {
                teardownTransport()
                let retryable = (error as? DashHandshakeError).map {
                    $0 == .noReplyAtAll || $0 == .authNotReady
                } ?? false
                if retryable && attempt < K1G.bootRaceMaxAttempts && !Task.isCancelled {
                    state = .handshaking
                    lastMessage = "The dashboard is still starting up — retrying (\(attempt)/\(K1G.bootRaceMaxAttempts))…"
                    try? await Task.sleep(nanoseconds: UInt64(K1G.bootRaceRetryInterval * 1_000_000_000))
                    continue
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                state = .failed(message)
                lastMessage = message
                connectTask = nil
                return
            }
        }
        connectTask = nil
    }

    private func attemptHandshake(ssid: String) async throws {
        // Fresh connection → fresh sequence and reply buffer.
        seq.reset()
        received.removeAll()

        let socket = DashSocket()
        self.socket = socket
        try await socket.start()
        startReceiveLoop(socket)

        state = .handshaking
        lastMessage = "Pairing with the dashboard…"

        // 1) Initial burst (REQUEST_PUBKEY first), ~20 ms apart.
        for packet in InitialBurst.packets(hostname: hostname, seq: seq) {
            try Task.checkCancellation()
            try await socket.send(packet)
            try? await Task.sleep(nanoseconds: UInt64(K1G.burstPause * 1_000_000_000))
        }

        // 2) Await modulus (07 00) + exponent (07 03).
        let gotKey = await waitFor({ DashRsaHandshake.modulusAndExponent(from: $0) != nil },
                                   timeout: K1G.handshakeStepTimeout)
        try Task.checkCancellation()
        guard gotKey, let (modulus, exponent) = DashRsaHandshake.modulusAndExponent(from: received) else {
            throw received.isEmpty ? DashHandshakeError.noReplyAtAll
                                   : DashHandshakeError.missingSegment("encryption key")
        }

        // 3) Encrypt (ssid ‖ aesKey) and send SESSION_KEY.
        let publicKey = try DashRsaHandshake.makePublicKey(modulus: modulus, exponent: exponent)
        let aesKey = try DashRsaHandshake.makeAesKey()
        let ciphertext = try DashRsaHandshake.encryptSessionKey(ssid: ssid, aesKey: aesKey,
                                                                dashPublicKey: publicKey)
        try await socket.send(K1GPacket.makeSessionKey(ciphertext: ciphertext, seq: seq.consume()))

        // 4) Await auth-OK (07 01 01).
        let authOK = await waitFor({ DashRsaHandshake.isAuthOK($0) }, timeout: K1G.handshakeStepTimeout)
        try Task.checkCancellation()
        guard authOK else { throw DashHandshakeError.authNotReady }

        // Connected. Keep the link alive at 1 Hz.
        state = .connected
        lastMessage = "Connected to the dashboard."
        startHeartbeat(socket)
    }

    // MARK: - Receive loop + waiters

    private func startReceiveLoop(_ socket: DashSocket) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            for await packet in socket.inbound {
                let segments = K1GPacket.decode(packet)
                guard !segments.isEmpty else { continue }
                await self?.appendSegments(segments)
            }
        }
    }

    private func appendSegments(_ segments: [K1GSegment]) {
        received.append(contentsOf: segments)
        if let w = waiter, w.check(received) {
            waiter = nil
            w.resume(true)
        }
    }

    /// Resolve once `check` holds over the accumulated segments, or `false`
    /// on timeout.
    private func waitFor(_ check: @escaping ([K1GSegment]) -> Bool, timeout: TimeInterval) async -> Bool {
        if check(received) { return true }
        waiterCounter += 1
        let id = waiterCounter
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.waiter = (id, check, { cont.resume(returning: $0) })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let w = self.waiter, w.id == id {
                    self.waiter = nil
                    w.resume(false)
                }
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(_ socket: DashSocket) {
        heartbeatTask?.cancel()
        let seq = self.seq
        heartbeatTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                let t = await self?.telemetry() ?? .placeholder
                let hb = K1GPacket.makeHeartbeat0044(seq: seq.consume(),
                                                     cellSignal0to255: t.cellSignal0to255,
                                                     batteryPct0to100: t.batteryPct0to100,
                                                     gpsOn: t.gpsOn, charging: t.charging,
                                                     signalPresent: t.signalPresent)
                let md = K1GPacket.makeMetadata0030(seq: seq.consume(),
                                                    cellSignal0to255: t.cellSignal0to255)
                do {
                    try await socket.send(hb)
                    try await socket.send(md)
                    ticks += 1
                } catch {
                    await self?.linkDropped("Lost the connection to the dashboard.")
                    return
                }
                let silence = await socket.secondsSinceLastRx()
                if ticks >= 5 && silence > K1G.rxSilenceTimeout {
                    await self?.linkDropped("The dashboard stopped responding.")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(K1G.heartbeatInterval * 1_000_000_000))
            }
        }
    }

    private func linkDropped(_ message: String) {
        guard state.isConnected else { return }
        teardown()
        state = .failed(message)
        lastMessage = message
    }

    private func telemetry() -> PhoneTelemetry {
        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel  // -1 when unknown
        let pct = level >= 0 ? Int((level * 100).rounded()) : 80
        let charging = device.batteryState == .charging || device.batteryState == .full
        return PhoneTelemetry(cellSignal0to255: 160, batteryPct0to100: pct,
                              gpsOn: true, charging: charging, signalPresent: true)
        #else
        return .placeholder
        #endif
    }

    // MARK: - Teardown

    private func teardownTransport() {
        receiveTask?.cancel(); receiveTask = nil
        if let s = socket { Task { await s.cancel() } }
        socket = nil
        if let w = waiter { waiter = nil; w.resume(false) }
    }

    private func teardown() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        teardownTransport()
    }
}

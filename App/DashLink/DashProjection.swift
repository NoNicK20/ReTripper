//
//  DashProjection.swift
//  ReTripper
//
//  Drives the dash's video projection on top of a connected DashLink:
//  sends the nav-mode kick, starts the H.264/RTP stream from a FrameSource,
//  and signals each frame to the dash. The map renderer is a FrameSource
//  (a later stage); until then a TestPatternFrameSource proves the pipeline
//  reaches the screen.
//
//  Uses the K1G projection TLVs and RTP streamer ported from TripperDash++
//  by Martin Kolací (@kolaCZek). PolyForm Noncommercial 1.0.0 — see CREDITS.
//

import Foundation
import Combine

@MainActor
final class DashProjection: ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case projecting
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var metrics = RtpStreamerMetrics()

    private let link: DashLink
    private var streamer: RtpStreamer?

    init(link: DashLink) { self.link = link }

    /// Begin projecting `source` to the dash. Requires a connected link.
    func start(title: String = "ReTripper", source: FrameSource? = nil) {
        guard link.state.isConnected else {
            state = .failed("Connect to the dashboard first.")
            return
        }
        guard state == .idle || isFailed else { return }
        state = .starting
        let frames = source ?? DashProjection.defaultSource()

        Task { [weak self] in
            guard let self else { return }
            await self.link.sendNavKick(title: title)
            // Give the dash time to allocate its decoder surface.
            try? await Task.sleep(nanoseconds: 450_000_000)

            let streamer = RtpStreamer(source: frames)
            streamer.onFrameKick = { [weak self] in
                Task { await self?.link.sendProjectionFrame() }
            }
            streamer.onStreamFailed = { [weak self] in
                self?.handleStreamFailure()
            }
            streamer.onMetrics = { [weak self] m in self?.metrics = m }
            streamer.start()
            self.streamer = streamer

            await self.link.sendProjectionOn()
            self.state = .projecting
        }
    }

    func stop() {
        streamer?.stop()
        streamer = nil
        let link = self.link
        Task { await link.stopProjection() }
        state = .idle
    }

    private func handleStreamFailure() {
        streamer = nil
        state = .failed("The video stream to the dashboard failed.")
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// The real Google map when a Maps key is configured, otherwise the
    /// animated test pattern (so the pipeline is still visible on the dash).
    static func defaultSource() -> FrameSource {
        AppSecretsConfiguration.googleMapsAPIKey != nil
            ? GoogleMapFrameSource()
            : TestPatternFrameSource()
    }
}

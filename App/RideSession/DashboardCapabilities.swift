//
//  DashboardCapabilities.swift
//  ReTripper
//
//  Capability-gated interface for sending ride data to the Tripper Dash.
//
//  Royal Enfield has not published the Tripper Dash protocol. ReTripper does not
//  invent endpoints, packet formats or credentials, so every capability reports
//  `unavailable` and the output sink discards data. Wi-Fi association is tracked
//  separately (DashboardConnectionManager) and never counts as a dashboard session.
//  All phone-side features work without a motorcycle.
//

import Foundation

enum DashboardCapability: String, CaseIterable, Identifiable {
    case fullMap = "Full-map output"
    case turnByTurn = "Turn-by-turn output"
    case tripStatistics = "Trip statistics"
    case musicState = "Music state"
    case callAlerts = "Call alerts"
    case contextualAlerts = "Contextual alerts"
    case compass = "Compass"
    case audioGuidance = "Audio guidance"

    var id: String { rawValue }
}

enum CapabilityAvailability: Equatable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool { self == .available }
}

/// Messages ReTripper would send to a dashboard if a verified protocol existed.
enum DashboardMessage: Equatable {
    case maneuver(symbol: String, distanceMeters: Double, road: String?)
    case trip(distanceKm: Double, movingSeconds: TimeInterval, avgKmh: Double)
    case music(title: String, artist: String?, playing: Bool)
    case call(phase: String)
    case alert(title: String)
    case heading(degrees: Double)
}

protocol DashboardOutput {
    func send(_ message: DashboardMessage) -> Bool
}

/// Used until a verified protocol is implemented: accepts nothing.
struct UnavailableDashboardOutput: DashboardOutput {
    func send(_ message: DashboardMessage) -> Bool { false }
}

/// Modular navigation feed for a future, verified dashboard interface.
/// Converts navigation progress into dashboard messages and sends them only when
/// the turn-by-turn capability is available. Today nothing is sent.
/// Note: rendering Google Maps imagery on another display would also need
/// Google Maps Platform licensing review; only text/maneuver data is modelled here.
@MainActor
final class DashboardNavigationFeed {
    private let registry: () -> DashboardCapabilityRegistry
    private(set) var lastMessage: DashboardMessage?
    private(set) var sentCount = 0

    init(registry: @escaping () -> DashboardCapabilityRegistry) {
        self.registry = registry
    }

    @discardableResult
    func publish(progress: RouteProgress) -> Bool {
        let message = DashboardMessage.maneuver(symbol: progress.nextManeuver.rawValue,
                                                distanceMeters: progress.distanceToNextManeuverMeters,
                                                road: progress.nextRoadName)
        lastMessage = message
        let current = registry()
        guard current.availability(of: .turnByTurn).isAvailable else { return false }
        let sent = current.output.send(message)
        if sent { sentCount += 1 }
        return sent
    }
}

struct DashboardCapabilityRegistry {
    let protocolSupport: DashboardProtocolSupport
    let sessionEstablished: Bool

    static let audioNote = "Spoken guidance plays through the phone's audio route (for example a Bluetooth helmet headset), not through the dashboard."

    func availability(of capability: DashboardCapability) -> CapabilityAvailability {
        switch protocolSupport {
        case .notVerified:
            if capability == .audioGuidance {
                return .unavailable(reason: Self.audioNote)
            }
            return .unavailable(reason: "No verified Tripper Dash protocol. Royal Enfield has not published one, so ReTripper cannot send \(capability.rawValue.lowercased()).")
        }
    }

    var output: DashboardOutput {
        // Even with a session, only a verified protocol may enable output.
        UnavailableDashboardOutput()
    }

    var anyAvailable: Bool {
        DashboardCapability.allCases.contains { availability(of: $0).isAvailable }
    }
}

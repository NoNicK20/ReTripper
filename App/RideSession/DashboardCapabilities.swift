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

//
//  NavigationModels.swift
//  ReTripper
//
//  Navigation models shared by the Google navigation engine, UI and tests.
//

import Foundation
import CoreLocation

// MARK: - Maneuver

enum Maneuver: String, Codable, Equatable {
    case depart, straight, left, right, slightLeft, slightRight, sharpLeft, sharpRight
    case uTurn, keepLeft, keepRight, roundabout, merge, exit, ferry, waypoint, arrive

    var symbolName: String {
        switch self {
        case .depart: return "location.north.fill"
        case .straight: return "arrow.up"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .sharpLeft: return "arrow.down.left"
        case .sharpRight: return "arrow.down.right"
        case .uTurn: return "arrow.uturn.down"
        case .keepLeft: return "arrow.up.left"
        case .keepRight: return "arrow.up.right"
        case .roundabout: return "arrow.triangle.2.circlepath"
        case .merge: return "arrow.merge"
        case .exit: return "arrow.up.right"
        case .ferry: return "ferry.fill"
        case .waypoint: return "mappin.circle.fill"
        case .arrive: return "flag.checkered"
        }
    }

    /// Derives a maneuver symbol from navigation instruction text.
    static func parse(instruction: String) -> Maneuver {
        let t = instruction.lowercased()
        if t.contains("arrive") || t.contains("destination") { return .arrive }
        if t.contains("u-turn") || t.contains("u turn") || t.contains("make a u") { return .uTurn }
        if t.contains("roundabout") || t.contains("rotary") || t.contains("traffic circle") { return .roundabout }
        if t.contains("ferry") { return .ferry }
        if t.contains("sharp left") { return .sharpLeft }
        if t.contains("sharp right") { return .sharpRight }
        if t.contains("slight left") || t.contains("bear left") { return .slightLeft }
        if t.contains("slight right") || t.contains("bear right") { return .slightRight }
        if t.contains("keep left") { return .keepLeft }
        if t.contains("keep right") { return .keepRight }
        if t.contains("exit") { return .exit }
        if t.contains("merge") { return .merge }
        if t.contains("turn left") || t.hasPrefix("left") { return .left }
        if t.contains("turn right") || t.hasPrefix("right") { return .right }
        if t.contains("proceed") || t.contains("head ") || t.hasPrefix("start") { return .depart }
        return .straight
    }

    /// Extracts a road name from instruction text such as "Turn right onto MG Road".
    static func roadName(from instruction: String) -> String? {
        for marker in [" onto ", " on to ", " on ", " toward ", " towards "] {
            if let range = instruction.range(of: marker, options: .caseInsensitive) {
                let name = instruction[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}

// MARK: - Destination

struct Destination: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var subtitle: String = ""
    var latitude: Double
    var longitude: Double
    /// Google Place ID from Places autocomplete. When present, navigation routes to the place ID.
    var placeID: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func isSamePlace(as other: Destination) -> Bool {
        if let a = placeID, let b = other.placeID { return a == b }
        if placeID != nil || other.placeID != nil { return false }
        return CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude)) < 30
    }
}

// MARK: - Progress

struct RouteProgress: Equatable {
    var stepIndex: Int
    var nextManeuver: Maneuver
    var nextInstruction: String
    var nextRoadName: String?
    var distanceToNextManeuverMeters: Double
    var remainingDistanceMeters: Double
    var remainingSeconds: TimeInterval
    var fractionComplete: Double

    var eta: Date { Date().addingTimeInterval(remainingSeconds) }
}

enum NavigationStatus: Equatable {
    case idle
    case calculating
    case preview
    case navigating
    case rerouting
    case arrived
    case failed(String)

    var isActive: Bool { self == .navigating || self == .rerouting }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Shared destination links

/// Parses destinations shared into ReTripper (custom URL scheme, geo: URIs,
/// Apple Maps and Google Maps links containing coordinates).
enum DestinationLinkParser {
    static func parse(_ text: String) -> Destination? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048 else { return nil }

        if trimmed.lowercased().hasPrefix("geo:") {
            let body = trimmed.dropFirst(4).split(separator: "?").first.map(String.init) ?? ""
            return coordinatePair(body, name: "Shared location")
        }

        guard let components = URLComponents(string: trimmed) else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? { items.first(where: { $0.name == key })?.value }

        if components.scheme == "retripper" {
            guard let lat = value("lat").flatMap(Double.init), let lon = value("lon").flatMap(Double.init) else { return nil }
            return make(lat, lon, name: value("name") ?? "Shared destination")
        }

        let host = components.host?.lowercased() ?? ""
        let isAppleMaps = host.hasSuffix("maps.apple.com")
        let isGoogleMaps = host.contains("google.") || host.hasSuffix("goo.gl")
        guard isAppleMaps || isGoogleMaps else { return nil }

        let name = value("q").flatMap { coordinatePair($0, name: "") == nil ? $0 : nil } ?? "Shared location"
        for key in ["ll", "daddr", "destination", "q", "query", "sll"] {
            if let raw = value(key), let d = coordinatePair(raw, name: name) { return d }
        }
        // Google "/@lat,lon,zoom" path form.
        if let at = components.path.range(of: "@") {
            let tail = components.path[at.upperBound...]
            let parts = tail.split(separator: ",")
            if parts.count >= 2 { return coordinatePair("\(parts[0]),\(parts[1])", name: name) }
        }
        return nil
    }

    static func coordinatePair(_ text: String, name: String) -> Destination? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return make(lat, lon, name: name)
    }

    private static func make(_ lat: Double, _ lon: Double, name: String) -> Destination? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        let cleanName = String(name.prefix(120))
        return Destination(name: cleanName.isEmpty ? "Shared location" : cleanName,
                           subtitle: String(format: "%.5f, %.5f", lat, lon),
                           latitude: lat, longitude: lon)
    }
}

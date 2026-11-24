//
//  NavigationModels.swift
//  ReTripper
//
//  Provider-neutral navigation models plus pure route-progress tracking.
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

    /// Derives a maneuver from provider instruction text (MapKit does not expose a maneuver type).
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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func isSamePlace(as other: Destination) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude)) < 30
    }
}

// MARK: - Route

struct NavStep: Equatable {
    var instruction: String
    var maneuver: Maneuver
    var roadName: String?
    var distanceMeters: Double
    var coordinates: [CLLocationCoordinate2D]

    static func == (lhs: NavStep, rhs: NavStep) -> Bool {
        lhs.instruction == rhs.instruction && lhs.distanceMeters == rhs.distanceMeters
            && lhs.coordinates.count == rhs.coordinates.count
    }
}

struct NavRoute: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var distanceMeters: Double
    var expectedTravelSeconds: TimeInterval
    var steps: [NavStep]
    var advisories: [String] = []
    var stops: [Destination]
    /// Provider that produced this route, shown to the rider.
    var sourceLabel: String

    var coordinates: [CLLocationCoordinate2D] { steps.flatMap { $0.coordinates } }

    static func == (lhs: NavRoute, rhs: NavRoute) -> Bool { lhs.id == rhs.id }
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
    var distanceFromRouteMeters: Double

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

/// Which engine is producing guidance. Shown to the rider so MapKit is never presented as Google.
enum NavigationEngine: String, Equatable {
    case appleMapKit = "Apple Maps (MapKit)"
    case googleNavigationSDK = "Google Maps Navigation SDK"
}

// MARK: - Pure progress tracker

/// Projects the rider's position onto a route polyline to compute live progress
/// and detect route deviation. Independent of any map SDK, so it is unit-testable.
struct RouteProgressTracker {
    struct Config {
        var offRouteThresholdMeters: Double = 45
        var offRouteConsecutiveSamples: Int = 3
        var arrivalThresholdMeters: Double = 30
    }

    let route: NavRoute
    var config = Config()

    private let points: [CLLocationCoordinate2D]
    private let cumulative: [Double]        // distance along route at each point
    private let stepEndDistance: [Double]   // distance along route where each step ends
    private let totalLength: Double
    private(set) var offRouteCount = 0
    private(set) var lastAlong: Double = 0

    init(route: NavRoute, config: Config = Config()) {
        self.route = route
        self.config = config
        var pts: [CLLocationCoordinate2D] = []
        var cum: [Double] = []
        var ends: [Double] = []
        var running = 0.0
        for step in route.steps {
            for c in step.coordinates {
                if let last = pts.last {
                    running += RouteProgressTracker.distance(last, c)
                }
                pts.append(c)
                cum.append(running)
            }
            ends.append(running)
        }
        points = pts
        cumulative = cum
        stepEndDistance = ends
        totalLength = max(running, 1)
    }

    enum Outcome: Equatable {
        case onRoute(RouteProgress)
        case offRoute(distanceMeters: Double)
        case arrived
        case noGeometry
    }

    mutating func update(with location: CLLocationCoordinate2D, accuracy: Double = 10) -> Outcome {
        guard points.count >= 2 else { return .noGeometry }
        var bestDistance = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        for i in 0..<(points.count - 1) {
            let (d, t) = RouteProgressTracker.project(location, onto: points[i], points[i + 1])
            if d < bestDistance {
                bestDistance = d
                bestAlong = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
            }
        }

        let threshold = config.offRouteThresholdMeters + max(0, min(accuracy, 50))
        if bestDistance > threshold {
            offRouteCount += 1
            if offRouteCount >= config.offRouteConsecutiveSamples {
                return .offRoute(distanceMeters: bestDistance)
            }
        } else {
            offRouteCount = 0
        }

        lastAlong = bestAlong
        let remaining = max(0, totalLength - bestAlong)
        if remaining <= config.arrivalThresholdMeters { return .arrived }

        let stepIndex = stepEndDistance.firstIndex(where: { bestAlong < $0 }) ?? max(0, route.steps.count - 1)
        let nextIndex = stepIndex + 1
        let next = nextIndex < route.steps.count ? route.steps[nextIndex] : nil
        let toManeuver = max(0, (stepEndDistance[safe: stepIndex] ?? totalLength) - bestAlong)
        let fraction = min(1, max(0, bestAlong / totalLength))

        return .onRoute(RouteProgress(
            stepIndex: stepIndex,
            nextManeuver: next?.maneuver ?? .arrive,
            nextInstruction: next?.instruction ?? "Arrive at \(route.stops.last?.name ?? "destination")",
            nextRoadName: next?.roadName,
            distanceToNextManeuverMeters: toManeuver,
            remainingDistanceMeters: remaining,
            remainingSeconds: route.expectedTravelSeconds * (remaining / totalLength),
            fractionComplete: fraction,
            distanceFromRouteMeters: bestDistance
        ))
    }

    // MARK: Geometry helpers (local equirectangular approximation, accurate at route scale)

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Returns (distance in meters from p to segment ab, fraction t along the segment).
    static func project(_ p: CLLocationCoordinate2D, onto a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (Double, Double) {
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(p.latitude * .pi / 180)
        let ax = (a.longitude - p.longitude) * metersPerDegLon, ay = (a.latitude - p.latitude) * metersPerDegLat
        let bx = (b.longitude - p.longitude) * metersPerDegLon, by = (b.latitude - p.latitude) * metersPerDegLat
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        var t = 0.0
        if lengthSquared > 0 {
            t = max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
        }
        let cx = ax + t * dx, cy = ay + t * dy
        return ((cx * cx + cy * cy).squareRoot(), t)
    }
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

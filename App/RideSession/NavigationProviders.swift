//
//  NavigationProviders.swift
//  ReTripper
//
//  Route/search provider abstraction and the Apple MapKit implementation.
//  The MapKit provider is always available and is the buildable fallback.
//

import Foundation
import MapKit
import CoreLocation

enum NavigationProviderError: LocalizedError {
    case noRoute
    case noStops
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .noRoute: return "No route was found to this destination."
        case .noStops: return "Choose a destination first."
        case .notConfigured(let reason): return reason
        }
    }
}

protocol NavigationRouteProvider: AnyObject {
    var engine: NavigationEngine { get }
    func searchDestinations(query: String, near: CLLocationCoordinate2D?) async throws -> [Destination]
    /// Returns one or more candidate routes from `origin` through all `stops` in order.
    /// Alternatives are returned when the provider supports them.
    func calculateRoutes(from origin: CLLocationCoordinate2D, stops: [Destination]) async throws -> [NavRoute]
}

final class MapKitRouteProvider: NavigationRouteProvider {
    let engine: NavigationEngine = .appleMapKit

    func searchDestinations(query: String, near: CLLocationCoordinate2D?) async throws -> [Destination] {
        let cleaned = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !cleaned.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = cleaned
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(20).map { item in
            let c = item.placemark.coordinate
            return Destination(name: item.name ?? "Unnamed place",
                               subtitle: item.placemark.title ?? "",
                               latitude: c.latitude, longitude: c.longitude)
        }
    }

    func calculateRoutes(from origin: CLLocationCoordinate2D, stops: [Destination]) async throws -> [NavRoute] {
        guard !stops.isEmpty else { throw NavigationProviderError.noStops }

        if stops.count == 1 {
            let routes = try await legs(from: origin, to: stops[0].coordinate, alternatives: true)
            return routes.map { makeRoute(from: [$0], stops: stops) }
        }

        // MapKit routes one leg at a time; chain legs through each waypoint.
        var legRoutes: [MKRoute] = []
        var legStart = origin
        for stop in stops {
            guard let leg = try await legs(from: legStart, to: stop.coordinate, alternatives: false).first else {
                throw NavigationProviderError.noRoute
            }
            legRoutes.append(leg)
            legStart = stop.coordinate
        }
        return [makeRoute(from: legRoutes, stops: stops)]
    }

    private func legs(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, alternatives: Bool) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        // MapKit has no motorcycle mode; automobile is the closest supported option.
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternatives
        request.departureDate = Date()
        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw NavigationProviderError.noRoute }
        return response.routes
    }

    private func makeRoute(from legs: [MKRoute], stops: [Destination]) -> NavRoute {
        var steps: [NavStep] = []
        for (legIndex, leg) in legs.enumerated() {
            for step in leg.steps {
                let coords = MapKitRouteProvider.coordinates(of: step.polyline)
                guard !coords.isEmpty else { continue }
                let text = step.instructions.isEmpty
                    ? (steps.isEmpty ? "Start route" : "Continue")
                    : step.instructions
                steps.append(NavStep(instruction: text,
                                     maneuver: Maneuver.parse(instruction: text),
                                     roadName: Maneuver.roadName(from: text),
                                     distanceMeters: step.distance,
                                     coordinates: coords))
            }
            if legIndex < legs.count - 1, let last = steps.last, let end = last.coordinates.last {
                steps.append(NavStep(instruction: "Arrive at waypoint \(stops[legIndex].name)",
                                     maneuver: .waypoint, roadName: nil, distanceMeters: 0,
                                     coordinates: [end]))
            }
        }
        let names = legs.map { $0.name }.filter { !$0.isEmpty }
        return NavRoute(
            name: names.isEmpty ? "Route" : "via " + names.joined(separator: ", "),
            distanceMeters: legs.reduce(0) { $0 + $1.distance },
            expectedTravelSeconds: legs.reduce(0) { $0 + $1.expectedTravelTime },
            steps: steps,
            advisories: legs.flatMap { $0.advisoryNotices },
            stops: stops,
            sourceLabel: engine.rawValue
        )
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }
}

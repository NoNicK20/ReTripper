//
//  RoutesAPIClient.swift
//  ReTripper
//
//  Self-serve routing via the Google Routes API (directions/v2:computeRoutes).
//  Unlike the Navigation SDK (which needs a key enabled by Google sales), the
//  Routes API is a standard pay-as-you-go web service that works on an ordinary
//  Google Maps key. ReTripper asks it for the route, then draws the line itself
//  on the map (and, later, on the dash). Reuses the app's GMSApiKey and sends
//  the iOS bundle-identifier header so an app-restricted key is accepted.
//

import Foundation
import CoreLocation

/// One maneuver of a computed route (for turn-by-turn and the dash overlay).
struct RouteStepInfo {
    let instruction: String
    let maneuver: String
    let distanceMeters: Double
    let encodedPolyline: String?
}

/// A computed route: the full encoded line, totals, and per-step detail.
struct RouteResult {
    let encodedPolyline: String
    let distanceMeters: Double
    let durationSeconds: Double
    let steps: [RouteStepInfo]
}

enum RoutesAPIError: Error, LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case noRoute
    case decode

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no Google Maps key, so routing is off."
        case .noRoute:
            return "No route could be found to that destination. Try a nearby address."
        case .decode:
            return "Couldn't read the route Google sent back."
        case let .http(code, message):
            return RoutesAPIError.describeHTTP(code: code, googleMessage: message)
        }
    }

    static func describeHTTP(code: Int, googleMessage: String) -> String {
        switch code {
        case 403:
            if googleMessage.localizedCaseInsensitiveContains("has not been used")
                || googleMessage.localizedCaseInsensitiveContains("disabled") {
                return "Routes API isn't enabled for this Google key. Turn on \"Routes API\" in Google Cloud."
            }
            if googleMessage.localizedCaseInsensitiveContains("restriction")
                || googleMessage.localizedCaseInsensitiveContains("blocked")
                || googleMessage.localizedCaseInsensitiveContains("referer") {
                return "The Google key is restricted and is blocking routing. Add \"Routes API\" to the key's allowed APIs."
            }
            return "Routing was denied (403). Check the key's API restrictions and that Routes API is on."
        case 429:
            // A 429 on an otherwise-working key is almost always an account
            // setting, not real traffic. Google's own message usually says which,
            // so surface it instead of hiding it behind "try again later".
            if googleMessage.localizedCaseInsensitiveContains("billing") {
                return "Google blocked routing because billing isn't enabled on your Google Cloud project. "
                    + "Routes API needs a billing account linked (Google still gives free monthly usage, "
                    + "but a card must be on file). Enable billing in Google Cloud, then try again."
            }
            if googleMessage.localizedCaseInsensitiveContains("per minute")
                || googleMessage.localizedCaseInsensitiveContains("per user")
                || googleMessage.localizedCaseInsensitiveContains("rate") {
                return "Too many route requests in a short time (429). Wait a minute and try again."
            }
            return "Google's routing quota was hit (429). Check billing is enabled and the Routes API quota "
                + "in Google Cloud isn't set to 0."
                + (googleMessage.isEmpty ? "" : " Google said: \(googleMessage)")
        default:
            return "Routing failed (HTTP \(code))." + (googleMessage.isEmpty ? "" : " \(googleMessage)")
        }
    }
}

struct RoutesAPIClient {

    enum TravelMode: String {
        case drive = "DRIVE"
        case twoWheeler = "TWO_WHEELER"
        case bicycle = "BICYCLE"
        case walk = "WALK"
    }

    /// A route endpoint: a Place ID when we have one (more accurate), else a coordinate.
    struct Waypoint {
        let coordinate: CLLocationCoordinate2D
        let placeID: String?
    }

    private let apiKey: String?
    private let bundleID: String?
    private let session: URLSession

    init(apiKey: String? = AppSecretsConfiguration.googleMapsAPIKey,
         bundleID: String? = Bundle.main.bundleIdentifier,
         session: URLSession = URLSession(configuration: .ephemeral)) {
        self.apiKey = apiKey
        self.bundleID = bundleID
        self.session = session
    }

    var isConfigured: Bool { apiKey != nil }

    func compute(origin: CLLocationCoordinate2D,
                 destination: Waypoint,
                 intermediates: [Waypoint],
                 mode: TravelMode) async throws -> RouteResult {
        guard let apiKey,
              let url = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes") else {
            throw RoutesAPIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        if let bundleID { request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        request.setValue(Self.fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")

        var body: [String: Any] = [
            "origin": ["location": ["latLng": Self.latLng(origin)]],
            "destination": Self.waypointJSON(destination),
            "travelMode": mode.rawValue,
            "polylineEncoding": "ENCODED_POLYLINE",
            "computeAlternativeRoutes": false,
            "languageCode": "en-US",
            "units": "METRIC",
        ]
        if !intermediates.isEmpty {
            body["intermediates"] = intermediates.map { Self.waypointJSON($0) }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw RoutesAPIError.http(code, Self.googleError(data))
        }
        return try Self.parse(data)
    }

    // MARK: - JSON helpers (static, so they're unit-testable without the network)

    static let fieldMask =
        "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline," +
        "routes.legs.steps.navigationInstruction,routes.legs.steps.distanceMeters," +
        "routes.legs.steps.polyline.encodedPolyline"

    static func latLng(_ c: CLLocationCoordinate2D) -> [String: Any] {
        ["latitude": c.latitude, "longitude": c.longitude]
    }

    static func waypointJSON(_ wp: Waypoint) -> [String: Any] {
        if let placeID = wp.placeID, !placeID.isEmpty { return ["placeId": placeID] }
        return ["location": ["latLng": latLng(wp.coordinate)]]
    }

    static func googleError(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let message = err["message"] as? String else { return "" }
        return message
    }

    static func parse(_ data: Data) throws -> RouteResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoutesAPIError.decode
        }
        guard let routes = obj["routes"] as? [[String: Any]], let first = routes.first else {
            throw RoutesAPIError.noRoute
        }
        guard let encoded = (first["polyline"] as? [String: Any])?["encodedPolyline"] as? String,
              !encoded.isEmpty else {
            throw RoutesAPIError.decode
        }
        let distance = (first["distanceMeters"] as? NSNumber)?.doubleValue ?? 0
        let durationString = (first["duration"] as? String) ?? "0s"
        let duration = Double(durationString.replacingOccurrences(of: "s", with: "")) ?? 0

        var steps: [RouteStepInfo] = []
        for leg in (first["legs"] as? [[String: Any]]) ?? [] {
            for step in (leg["steps"] as? [[String: Any]]) ?? [] {
                let nav = step["navigationInstruction"] as? [String: Any]
                steps.append(RouteStepInfo(
                    instruction: (nav?["instructions"] as? String) ?? "",
                    maneuver: (nav?["maneuver"] as? String) ?? "",
                    distanceMeters: (step["distanceMeters"] as? NSNumber)?.doubleValue ?? 0,
                    encodedPolyline: (step["polyline"] as? [String: Any])?["encodedPolyline"] as? String))
            }
        }
        return RouteResult(encodedPolyline: encoded, distanceMeters: distance,
                           durationSeconds: duration, steps: steps)
    }
}

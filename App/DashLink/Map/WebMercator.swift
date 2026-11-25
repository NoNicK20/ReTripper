//
//  WebMercator.swift
//  ReTripper
//
//  Web Mercator tile math for the Google Map Tiles renderer: latitude /
//  longitude ↔ world-pixel and tile coordinates at a given zoom. Tiles are
//  256 px (Google Map Tiles 2D tiles).
//

import CoreLocation
import Foundation

enum WebMercator {
    static let tileSize: Double = 256
    /// Latitude limit of the Web Mercator projection.
    static let maxLatitude: Double = 85.05112878

    /// World-pixel coordinate (origin top-left, y increasing south) at `zoom`.
    static func worldPixel(_ coord: CLLocationCoordinate2D, zoom: Int) -> CGPoint {
        let lat = min(max(coord.latitude, -maxLatitude), maxLatitude)
        let scale = tileSize * pow(2.0, Double(zoom))
        let x = (coord.longitude + 180.0) / 360.0 * scale
        let sinLat = sin(lat * .pi / 180.0)
        let y = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * scale
        return CGPoint(x: x, y: y)
    }

    /// The tile index containing `coord` at `zoom`.
    static func tileIndex(_ coord: CLLocationCoordinate2D, zoom: Int) -> (x: Int, y: Int) {
        let p = worldPixel(coord, zoom: zoom)
        return (Int(floor(p.x / tileSize)), Int(floor(p.y / tileSize)))
    }

    /// Number of tiles per axis at `zoom`.
    static func tileCount(zoom: Int) -> Int { 1 << zoom }

    /// Clamp a tile coordinate into the valid range for `zoom` (x wraps,
    /// y clamps).
    static func wrap(x: Int, y: Int, zoom: Int) -> (x: Int, y: Int)? {
        let n = tileCount(zoom: zoom)
        guard y >= 0 && y < n else { return nil }
        let wx = ((x % n) + n) % n
        return (wx, y)
    }
}

//
//  EncodedPolyline.swift
//  ReTripper
//
//  Decoder for Google's encoded-polyline format (used by the Routes API).
//  Pure Swift, no SDK dependency, so the route geometry is unit-testable.
//

import CoreLocation
import Foundation

enum EncodedPolyline {
    /// Decodes an encoded polyline string into coordinates.
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lng = 0
        var coords: [CLLocationCoordinate2D] = []

        func nextDelta() -> Int? {
            var result = 0
            var shift = 0
            while true {
                guard index < bytes.count else { return nil }
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { break }
            }
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < bytes.count {
            guard let dLat = nextDelta(), let dLng = nextDelta() else { break }
            lat += dLat
            lng += dLng
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5,
                                                 longitude: Double(lng) / 1e5))
        }
        return coords
    }
}

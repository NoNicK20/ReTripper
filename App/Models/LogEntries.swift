//
//  LogEntries.swift
//  ReTripper
//
//  Structured data models for Fuel, Maintenance, and Rides.
//

import Foundation

struct FuelLog: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var odometer: Double
    var liters: Double
    var totalCost: Double
    var isFullTank: Bool = true
    var notes: String = ""
    // Price per litre at the time of the fill. Optional so older saved logs still decode.
    var pricePerLiter: Double? = nil
}

struct MaintenanceLog: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var odometer: Double
    var title: String
    var totalCost: Double
    var serviceCenter: String = ""
    var notes: String = ""
}

struct RideLog: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var title: String
    var distance: Double
    var durationMinutes: Int = 0
    var endingOdometer: Double = 0.0
    var notes: String = ""
    // Phone-GPS ride statistics (optional so older saved rides still decode).
    var movingMinutes: Int? = nil
    var averageMovingSpeedKmh: Double? = nil
    var maxSpeedKmh: Double? = nil
    var elevationGainMeters: Double? = nil
    var route: [RoutePoint]? = nil
    /// "phone-gps" for rides recorded in Ride Mode; nil for manual entries.
    var source: String? = nil
}

enum ActivityType {
    case fuel
    case maintenance
    case ride
}

struct ActivityItem: Identifiable {
    let id: UUID
    let date: Date
    let type: ActivityType
    let title: String
    let subtitle: String
    let value: String
}

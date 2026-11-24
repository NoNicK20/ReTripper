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

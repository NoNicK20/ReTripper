//
//  Motorcycle.swift
//  ReTripper
//
//  Profile representation for Royal Enfield Guerrilla 450 Apex Red.
//

import Foundation

enum DistanceUnit: String, Codable, CaseIterable {
    case kilometers = "km"
    case miles = "mi"

    var label: String {
        switch self {
        case .kilometers: return "Kilometers (km)"
        case .miles: return "Miles (mi)"
        }
    }

    var shortLabel: String { rawValue }
}

struct Motorcycle: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var make: String = "Royal Enfield"
    var model: String = "Guerrilla 450"
    var edition: String = "Apex Red"
    var year: Int = 2024
    var registrationNumber: String = ""
    var vin: String = ""
    var currentOdometer: Double = 0.0
    var fuelCapacityLiters: Double = 11.0
    var notes: String = ""

    var displayName: String {
        "\(make) \(model)"
    }

    var fullEditionName: String {
        "\(model) — \(edition)"
    }

    static var defaultGuerrilla: Motorcycle {
        Motorcycle(
            make: "Royal Enfield",
            model: "Guerrilla 450",
            edition: "Apex Red",
            year: 2024,
            registrationNumber: "",
            vin: "",
            currentOdometer: 0.0,
            fuelCapacityLiters: 11.0,
            notes: ""
        )
    }
}

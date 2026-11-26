//
//  DataManager.swift
//  ReTripper
//
//  Offline-first local persistence manager using JSON storage in Documents.
//

import Foundation
import Combine

private struct StoragePayload: Codable {
    var motorcycle: Motorcycle?
    var fuelLogs: [FuelLog]?
    var maintenanceLogs: [MaintenanceLog]?
    var rideLogs: [RideLog]?
    var distanceUnit: DistanceUnit?
}

@MainActor
class DataManager: ObservableObject {
    static let shared = DataManager()

    @Published var motorcycle: Motorcycle
    @Published var fuelLogs: [FuelLog]
    @Published var maintenanceLogs: [MaintenanceLog]
    @Published var rideLogs: [RideLog]
    @Published var distanceUnit: DistanceUnit

    private let fileURL: URL

    init() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let directory = paths.first ?? FileManager.default.temporaryDirectory
        self.fileURL = directory.appendingPathComponent("retripper_storage.json")

        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(StoragePayload.self, from: data) {
            self.motorcycle = payload.motorcycle ?? Motorcycle.defaultGuerrilla
            self.fuelLogs = payload.fuelLogs ?? []
            self.maintenanceLogs = payload.maintenanceLogs ?? []
            self.rideLogs = payload.rideLogs ?? []
            self.distanceUnit = payload.distanceUnit ?? .kilometers
        } else {
            self.motorcycle = Motorcycle.defaultGuerrilla
            self.fuelLogs = []
            self.maintenanceLogs = []
            self.rideLogs = []
            self.distanceUnit = .kilometers
        }
    }

    func save() {
        let payload = StoragePayload(
            motorcycle: motorcycle,
            fuelLogs: fuelLogs,
            maintenanceLogs: maintenanceLogs,
            rideLogs: rideLogs,
            distanceUnit: distanceUnit
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomicWrite])
        } catch {
            print("Failed to save ReTripper data: \(error.localizedDescription)")
        }
    }

    // MARK: - Mutations
    func updateMotorcycle(_ updated: Motorcycle) {
        var clean = updated
        if clean.currentOdometer < 0 { clean.currentOdometer = 0 }
        self.motorcycle = clean
        save()
    }

    func updateOdometerIfHigher(_ reading: Double) {
        guard reading >= 0 else { return }
        if reading > motorcycle.currentOdometer {
            motorcycle.currentOdometer = reading
            save()
        }
    }

    func addFuelLog(_ log: FuelLog) {
        guard log.liters > 0, log.odometer >= 0, log.totalCost >= 0 else { return }
        fuelLogs.insert(log, at: 0)
        updateOdometerIfHigher(log.odometer)
        save()
    }

    func addMaintenanceLog(_ log: MaintenanceLog) {
        guard !log.title.trimmingCharacters(in: .whitespaces).isEmpty, log.odometer >= 0, log.totalCost >= 0 else { return }
        maintenanceLogs.insert(log, at: 0)
        updateOdometerIfHigher(log.odometer)
        save()
    }

    func addRideLog(_ log: RideLog) {
        guard log.distance > 0 || log.endingOdometer > motorcycle.currentOdometer else { return }
        rideLogs.insert(log, at: 0)
        if log.endingOdometer > 0 {
            updateOdometerIfHigher(log.endingOdometer)
        } else if log.distance > 0 {
            motorcycle.currentOdometer += log.distance
        }
        save()
    }

    func updateFuelLog(_ updated: FuelLog) {
        guard updated.liters > 0, updated.odometer >= 0, updated.totalCost >= 0 else { return }
        guard let idx = fuelLogs.firstIndex(where: { $0.id == updated.id }) else { return }
        fuelLogs[idx] = updated
        fuelLogs.sort { $0.date > $1.date }
        updateOdometerIfHigher(updated.odometer)
        save()
    }

    func deleteFuelLog(id: UUID) {
        fuelLogs.removeAll { $0.id == id }
        save()
    }

    func deleteFuelLog(at offsets: IndexSet) {
        fuelLogs.remove(atOffsets: offsets)
        save()
    }

    func deleteMaintenanceLog(at offsets: IndexSet) {
        maintenanceLogs.remove(atOffsets: offsets)
        save()
    }

    func deleteRideLog(at offsets: IndexSet) {
        rideLogs.remove(atOffsets: offsets)
        save()
    }

    func resetAllData() {
        self.motorcycle = Motorcycle.defaultGuerrilla
        self.fuelLogs = []
        self.maintenanceLogs = []
        self.rideLogs = []
        self.distanceUnit = .kilometers
        save()
    }

    // MARK: - Aggregations
    var recentActivities: [ActivityItem] {
        var items: [ActivityItem] = []

        for fuel in fuelLogs {
            items.append(ActivityItem(
                id: fuel.id,
                date: fuel.date,
                type: .fuel,
                title: "Fuel Refill",
                subtitle: String(format: "%.1f L @ %.0f %@", fuel.liters, fuel.odometer, distanceUnit.shortLabel),
                value: String(format: "%.2f", fuel.totalCost)
            ))
        }

        for maint in maintenanceLogs {
            items.append(ActivityItem(
                id: maint.id,
                date: maint.date,
                type: .maintenance,
                title: maint.title,
                subtitle: String(format: "Service at %.0f %@", maint.odometer, distanceUnit.shortLabel),
                value: String(format: "%.2f", maint.totalCost)
            ))
        }

        for ride in rideLogs {
            items.append(ActivityItem(
                id: ride.id,
                date: ride.date,
                type: .ride,
                title: ride.title,
                subtitle: ride.durationMinutes > 0 ? "\(ride.durationMinutes) min ride" : "Logged ride",
                value: String(format: "+%.1f %@", ride.distance, distanceUnit.shortLabel)
            ))
        }

        return items.sorted(by: { $0.date > $1.date })
    }
}

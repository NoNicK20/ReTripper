//
//  ContextualAlertManager.swift
//  ReTripper
//
//  Central alert system for the ride screen: prioritisation, deduplication,
//  cooldowns and automatic dismissal, so riders are not distracted by repeats.
//  Alerts are phone-side advisories only. They never replace or override the
//  motorcycle's own instrument warnings, and no weather or vehicle data is invented.
//

import Foundation
import UIKit
import Combine

enum AlertCategory: String, CaseIterable, Codable {
    case maneuver, routeDeviation, navigationInterruption, dashboard, gpsSignal
    case battery, maintenance, fuel, weather, vehicle, call, ride
}

enum AlertPriority: Int, Comparable, Codable {
    case info = 0, advisory = 1, warning = 2, critical = 3
    static func < (a: AlertPriority, b: AlertPriority) -> Bool { a.rawValue < b.rawValue }
}

struct RideAlert: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var category: AlertCategory
    var priority: AlertPriority
    var title: String
    var message: String
    var symbol: String
    var createdAt: Date
    /// nil = stays until dismissed or replaced.
    var expiresAt: Date?

    static func == (a: RideAlert, b: RideAlert) -> Bool {
        a.id == b.id && a.title == b.title && a.message == b.message && a.expiresAt == b.expiresAt
    }
}

/// Pure alert queue logic (testable with an injected clock).
struct AlertQueue {
    private(set) var active: [RideAlert] = []
    private var lastPosted: [String: Date] = [:]
    var maxActive = 4

    static func defaultCooldown(for category: AlertCategory) -> TimeInterval {
        switch category {
        case .maneuver, .call, .ride: return 0
        case .routeDeviation, .navigationInterruption, .dashboard: return 30
        case .gpsSignal: return 120
        case .battery: return 600
        case .maintenance, .fuel, .weather, .vehicle: return 3600
        }
    }

    /// Returns false when the alert was suppressed as a duplicate.
    @discardableResult
    mutating func post(_ alert: RideAlert, now: Date, cooldown: TimeInterval? = nil) -> Bool {
        expire(now: now)
        if let index = active.firstIndex(where: { $0.key == alert.key }) {
            // Same alert still showing: refresh its text and timeout instead of stacking a duplicate.
            var updated = alert
            updated.createdAt = active[index].createdAt
            active[index] = RideAlert(key: updated.key, category: updated.category, priority: updated.priority,
                                      title: updated.title, message: updated.message, symbol: updated.symbol,
                                      createdAt: updated.createdAt, expiresAt: updated.expiresAt)
            lastPosted[alert.key] = now
            return false
        }
        let wait = cooldown ?? Self.defaultCooldown(for: alert.category)
        if let last = lastPosted[alert.key], now.timeIntervalSince(last) < wait {
            return false
        }
        lastPosted[alert.key] = now
        active.append(alert)
        active.sort { ($0.priority, $0.createdAt) > ($1.priority, $1.createdAt) }
        if active.count > maxActive { active.removeLast(active.count - maxActive) }
        return true
    }

    mutating func expire(now: Date) {
        active.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
    }

    mutating func dismiss(key: String) {
        active.removeAll { $0.key == key }
    }

    mutating func dismiss(id: UUID) {
        active.removeAll { $0.id == id }
    }

    /// The single alert shown prominently: highest priority, newest first.
    var top: RideAlert? { active.first }
}

// MARK: - Reminder evaluation (pure)

enum ServiceReminder {
    /// Odometer values are in the rider's distance unit; `unitToKm` converts them.
    static func isServiceDue(currentOdometer: Double, lastServiceOdometer: Double?, lastServiceDate: Date?,
                             intervalKm: Double, intervalDays: Double, unitToKm: Double, now: Date) -> Bool {
        guard let lastOdo = lastServiceOdometer, let lastDate = lastServiceDate else { return false }
        let km = (currentOdometer - lastOdo) * unitToKm
        let days = now.timeIntervalSince(lastDate) / 86_400
        return km >= intervalKm || days >= intervalDays
    }

    /// Distance ridden since the last logged refuel, plus the current trip.
    static func kmSinceRefuel(currentOdometer: Double, lastFuelOdometer: Double?, currentTripKm: Double, unitToKm: Double) -> Double? {
        guard let fuelOdo = lastFuelOdometer else { return nil }
        return max(0, (currentOdometer - fuelOdo) * unitToKm) + currentTripKm
    }
}

// MARK: - Weather boundary

protocol WeatherAdvisoryProvider {
    var isConfigured: Bool { get }
    var statusDescription: String { get }
}

struct UnconfiguredWeatherProvider: WeatherAdvisoryProvider {
    let isConfigured = false
    let statusDescription = "No weather data provider is configured, so weather advisories are off."
}

// MARK: - Manager

@MainActor
final class ContextualAlertManager: ObservableObject {
    static let shared = ContextualAlertManager()

    @Published private(set) var alerts: [RideAlert] = []
    @Published var serviceIntervalKm: Double = 5000 { didSet { save() } }
    @Published var fuelReminderKm: Double = 250 { didSet { save() } }

    let weatherProvider: WeatherAdvisoryProvider = UnconfiguredWeatherProvider()
    /// No verified motorcycle telemetry source exists, so vehicle alerts are unavailable.
    let vehicleAlertsAvailable = false

    private var queue = AlertQueue()
    private var poorGpsSince: Date?
    private var batteryObservers: [NSObjectProtocol] = []

    init() {
        let d = UserDefaults.standard
        if d.double(forKey: "retripper_service_interval_km") > 0 { serviceIntervalKm = d.double(forKey: "retripper_service_interval_km") }
        if d.double(forKey: "retripper_fuel_reminder_km") > 0 { fuelReminderKm = d.double(forKey: "retripper_fuel_reminder_km") }
    }

    var top: RideAlert? { alerts.first }

    func post(_ category: AlertCategory, key: String? = nil, priority: AlertPriority, title: String,
              message: String, symbol: String, autoDismiss: TimeInterval? = 6, now: Date = Date()) {
        let alert = RideAlert(key: key ?? category.rawValue, category: category, priority: priority,
                              title: title, message: message, symbol: symbol, createdAt: now,
                              expiresAt: autoDismiss.map { now.addingTimeInterval($0) })
        queue.post(alert, now: now)
        alerts = queue.active
    }

    func dismiss(_ alert: RideAlert) {
        queue.dismiss(id: alert.id)
        alerts = queue.active
    }

    func dismiss(key: String) {
        queue.dismiss(key: key)
        alerts = queue.active
    }

    /// Called from the ride session's single 1 Hz tick.
    func tick(now: Date = Date()) {
        queue.expire(now: now)
        if alerts != queue.active { alerts = queue.active }
    }

    // MARK: Monitors

    func evaluateGPS(horizontalAccuracy: Double, now: Date = Date()) {
        let poor = horizontalAccuracy < 0 || horizontalAccuracy > 50
        if poor {
            if poorGpsSince == nil { poorGpsSince = now }
            if let since = poorGpsSince, now.timeIntervalSince(since) >= 10 {
                post(.gpsSignal, priority: .warning, title: "Weak GPS signal",
                     message: "Trip distance and guidance may be less accurate.",
                     symbol: "location.slash", autoDismiss: 8, now: now)
            }
        } else {
            poorGpsSince = nil
        }
    }

    func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard batteryObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            batteryObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.evaluateBattery() }
            })
        }
        evaluateBattery()
    }

    func stopBatteryMonitoring() {
        batteryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        batteryObservers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    func evaluateBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel   // -1 when unknown (e.g. Simulator)
        guard level >= 0, device.batteryState == .unplugged else { return }
        if level <= 0.10 {
            post(.battery, key: "battery-critical", priority: .critical, title: "Phone battery \(Int(level * 100))%",
                 message: "Navigation may stop soon. Connect the phone to power.", symbol: "battery.0", autoDismiss: 12)
        } else if level <= 0.20 {
            post(.battery, key: "battery-low", priority: .warning, title: "Phone battery \(Int(level * 100))%",
                 message: "Consider charging the phone.", symbol: "battery.25", autoDismiss: 8)
        }
    }

    /// Checks maintenance and fuel reminders using the rider's own logged records.
    func evaluateReminders(dataManager: DataManager, currentTripKm: Double, now: Date = Date()) {
        let unitToKm = dataManager.distanceUnit == .miles ? 1.609344 : 1.0
        let odo = dataManager.motorcycle.currentOdometer
        let lastService = dataManager.maintenanceLogs.max(by: { $0.date < $1.date })
        if ServiceReminder.isServiceDue(currentOdometer: odo, lastServiceOdometer: lastService?.odometer,
                                        lastServiceDate: lastService?.date, intervalKm: serviceIntervalKm,
                                        intervalDays: 365, unitToKm: unitToKm, now: now) {
            post(.maintenance, priority: .advisory, title: "Service reminder",
                 message: "Based on your service log, a service may be due.", symbol: "wrench.and.screwdriver", autoDismiss: 8, now: now)
        }
        let lastFuel = dataManager.fuelLogs.max(by: { $0.date < $1.date })
        if let km = ServiceReminder.kmSinceRefuel(currentOdometer: odo, lastFuelOdometer: lastFuel?.odometer,
                                                  currentTripKm: currentTripKm, unitToKm: unitToKm),
           km >= fuelReminderKm {
            post(.fuel, priority: .advisory, title: "Fuel stop suggestion",
                 message: String(format: "About %.0f km since your last logged refuel.", km),
                 symbol: "fuelpump", autoDismiss: 10, now: now)
        }
    }

    private func save() {
        UserDefaults.standard.set(serviceIntervalKm, forKey: "retripper_service_interval_km")
        UserDefaults.standard.set(fuelReminderKm, forKey: "retripper_fuel_reminder_km")
    }
}

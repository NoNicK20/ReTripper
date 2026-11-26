//
//  FuelMileageTests.swift
//  ReTripperTests
//
//  Tank-to-tank mileage and the two-way fill maths (pure arithmetic).
//

import XCTest
@testable import ReTripper

final class FuelEntryMathTests: XCTestCase {
    func testTotalCostFromLitresAndPrice() {
        XCTAssertEqual(FuelEntryMath.totalCost(liters: 8.5, pricePerLiter: 105.5), 896.75, accuracy: 0.001)
    }

    func testLitresFromTotalAndPrice() {
        XCTAssertEqual(FuelEntryMath.liters(totalCost: 896.75, pricePerLiter: 105.5), 8.5, accuracy: 0.001)
    }

    func testLitresIsZeroWhenPriceNonPositive() {
        XCTAssertEqual(FuelEntryMath.liters(totalCost: 500, pricePerLiter: 0), 0, accuracy: 0.001)
    }
}

final class FuelMileageTests: XCTestCase {

    private func fill(odo: Double, liters: Double, full: Bool, day: Int) -> FuelLog {
        FuelLog(date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                odometer: odo, liters: liters, totalCost: 0, isFullTank: full)
    }

    func testFullToFullIntervalEconomy() {
        // Fill full at 1000, ride 400 km, fill 10 L to full at 1400 → 40 km/L.
        let logs = [fill(odo: 1000, liters: 9, full: true, day: 1),
                    fill(odo: 1400, liters: 10, full: true, day: 2)]
        let ivals = FuelMileage.intervals(from: logs)
        XCTAssertEqual(ivals.count, 1)
        XCTAssertEqual(ivals[0].distance, 400, accuracy: 0.001)
        XCTAssertEqual(ivals[0].liters, 10, accuracy: 0.001)
        XCTAssertEqual(ivals[0].economy, 40, accuracy: 0.001)
        XCTAssertEqual(ivals[0].fillID, logs[1].id)
    }

    func testPartialFillBetweenFullTanksIsCounted() {
        // Full at 1000; partial 5 L at 1200; full 6 L at 1400.
        // Distance 400, fuel 5 + 6 = 11 → ~36.36 km/L.
        let logs = [fill(odo: 1000, liters: 8, full: true, day: 1),
                    fill(odo: 1200, liters: 5, full: false, day: 2),
                    fill(odo: 1400, liters: 6, full: true, day: 3)]
        let ivals = FuelMileage.intervals(from: logs)
        XCTAssertEqual(ivals.count, 1)
        XCTAssertEqual(ivals[0].distance, 400, accuracy: 0.001)
        XCTAssertEqual(ivals[0].liters, 11, accuracy: 0.001)
        XCTAssertEqual(ivals[0].economy, 400.0 / 11.0, accuracy: 0.001)
    }

    func testSingleFillHasNoInterval() {
        let logs = [fill(odo: 1000, liters: 9, full: true, day: 1)]
        XCTAssertTrue(FuelMileage.intervals(from: logs).isEmpty)
        XCTAssertNil(FuelMileage.latest(from: logs))
        XCTAssertNil(FuelMileage.average(from: logs))
    }

    func testAverageAcrossTwoIntervals() {
        // 1000→1400 full (10 L) → 40; 1400→1700 full (10 L) → 30.
        // Average = total distance 700 / total litres 20 = 35 km/L.
        let logs = [fill(odo: 1000, liters: 9, full: true, day: 1),
                    fill(odo: 1400, liters: 10, full: true, day: 2),
                    fill(odo: 1700, liters: 10, full: true, day: 3)]
        XCTAssertEqual(FuelMileage.average(from: logs)!, 35, accuracy: 0.001)
        XCTAssertEqual(FuelMileage.latest(from: logs)!.economy, 30, accuracy: 0.001)
    }

    func testUnsortedInputIsOrderedByOdometer() {
        let logs = [fill(odo: 1400, liters: 10, full: true, day: 2),
                    fill(odo: 1000, liters: 9, full: true, day: 1)]
        let ivals = FuelMileage.intervals(from: logs)
        XCTAssertEqual(ivals.count, 1)
        XCTAssertEqual(ivals[0].distance, 400, accuracy: 0.001)
    }
}

//
//  FuelCSVTests.swift
//  ReTripperTests
//
//  Importing a Fuelio export and round-tripping ReTripper's own CSV.
//

import XCTest
@testable import ReTripper

final class FuelCSVTests: XCTestCase {

    private let fuelio = """
    "## Vehicle"
    "Name","Description","DistUnit","FuelUnit","ConsumptionUnit","ImportCSVDateFormat","VIN","Insurance","Plate","Make","Model","Year","TankCount","Tank1Type","Tank2Type","Active","Tank1Capacity","Tank2Capacity","FuelUnitTank2","FuelConsumptionTank2","guid","lastupdated"
    "Guerrilla 450","","0","0","3","yyyy-MM-dd","","","","Royal Endield","Guerrilla","0","1","0","0","1","11.0","0.0","0","0","","0"
    "## Log"
    "Date","Odo (km)","Fuel (l)","Full","Price","km/l","latitude","longitude","City","Notes","Missed","TankNumber","FuelType","VolumePrice","StationID","ExcludeDistance","UniqueId","TankCalc","Weather","guid","lastupdated"
    "2026-05-09","15.0","9.0","1","1015.02","0.0","","","","Power","0","1","0","112.78","0","0.0","1","0.0","","","0"
    "2026-05-16","224.0","8.22","1","951.71","25.43","19.10813","73.0018","Navi Mumbai","Power","0","1","0","115.78","1017296","0.0","2","0.0","","","0"
    "2026-11-15","3527.0","5.45","0","660.1","26.6","","","","Normal, topped off","0","1","0","121.12","182831","0.0","21","0.0","","","0"
    "## CostCategories"
    "CostTypeID","Name","priority","color"
    """

    func testParsesFuelioLogSectionOnly() {
        let logs = FuelCSV.parse(fuelio)
        XCTAssertEqual(logs.count, 3)   // vehicle rows + the ## CostCategories marker are excluded
    }

    func testMapsColumnsByName() {
        let logs = FuelCSV.parse(fuelio)
        let first = logs[0]
        XCTAssertEqual(first.odometer, 15.0, accuracy: 0.001)
        XCTAssertEqual(first.liters, 9.0, accuracy: 0.001)
        XCTAssertEqual(first.totalCost, 1015.02, accuracy: 0.001)       // "Price" = total
        XCTAssertEqual(first.pricePerLiter ?? -1, 112.78, accuracy: 0.001) // "VolumePrice" = per litre
        XCTAssertTrue(first.isFullTank)
        XCTAssertEqual(first.notes, "Power")
    }

    func testHandlesFullFlagAndQuotedCommaNotes() {
        let last = FuelCSV.parse(fuelio)[2]
        XCTAssertFalse(last.isFullTank)                     // Full = 0
        XCTAssertEqual(last.notes, "Normal, topped off")    // comma inside a quoted field
    }

    func testRoundTripThroughReTripperExport() {
        let original = FuelCSV.parse(fuelio)
        let csv = FuelCSV.export(original, odometerUnit: "km")
        let reparsed = FuelCSV.parse(csv)
        XCTAssertEqual(reparsed.count, original.count)

        let byOdo = reparsed.sorted { $0.odometer < $1.odometer }
        XCTAssertEqual(byOdo[0].odometer, 15.0, accuracy: 0.001)
        XCTAssertEqual(byOdo[0].totalCost, 1015.02, accuracy: 0.01)
        XCTAssertEqual(byOdo[0].pricePerLiter ?? -1, 112.78, accuracy: 0.01)
        XCTAssertFalse(byOdo.first(where: { $0.odometer == 3527.0 })?.isFullTank ?? true)
    }

    func testEmptyForUnrelatedCSV() {
        XCTAssertTrue(FuelCSV.parse("foo,bar\n1,2\n").isEmpty)
    }
}

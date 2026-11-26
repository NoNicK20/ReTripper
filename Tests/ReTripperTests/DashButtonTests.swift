//
//  DashButtonTests.swift
//  ReTripperTests
//
//  Bike control-stick button decoding and echo-ack bytes. Byte codes are the
//  ones the community better-dash project verified against real hardware.
//

import XCTest
@testable import ReTripper

final class DashButtonTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testButtonByteCodes() {
        XCTAssertEqual(DashButton(rawValue: 0x13), .right)
        XCTAssertEqual(DashButton(rawValue: 0x14), .left)
        XCTAssertEqual(DashButton(rawValue: 0x15), .down)
        XCTAssertEqual(DashButton(rawValue: 0x18), .click)
        XCTAssertNil(DashButton(rawValue: 0x00))
    }

    func testAckMatchesBetterDashTemplate() {
        // 06 80 0001 XX wrapped in a valid K1G envelope (seg_count = 2).
        let ack = K1GPacket.makeButtonAck(buttonByte: 0x13, seq: 0)
        XCTAssertEqual(hex(ack), "0016000200000000020100054b314720000680000113")
    }

    func testAckCarriesTheButtonByte() {
        let ack = K1GPacket.makeButtonAck(buttonByte: 0x18, seq: 7)
        XCTAssertEqual(ack.last, 0x18)
    }

    func testDecodeInboundButtonSegment() {
        // [outer_len][seg_count][pad] then the 09 00 0001 15 TLV at offset 8.
        let packet = Data([0x00, 0x0D, 0x00, 0x02, 0, 0, 0, 0,
                           0x09, 0x00, 0x00, 0x01, 0x15])
        let segs = K1GPacket.decode(packet)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.type, K1G.SegType.button.rawValue)
        XCTAssertEqual(segs.first?.payload.first, 0x15)
        XCTAssertEqual(DashButton(rawValue: segs.first!.payload.first!), .down)
    }
}

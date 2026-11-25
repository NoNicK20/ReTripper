//
//  DashStreamTests.swift
//  ReTripperTests
//
//  RTP packetization (single-NAL + FU-A) and the K1G nav-projection TLVs.
//  The live H.264 encoder and UDP streaming can only be verified on a dash.
//

import XCTest
@testable import ReTripper

final class RtpPacketizerTests: XCTestCase {

    func testSingleNalPacket() {
        let packetizer = RtpPacketizer(maxPayloadSize: 1200, ssrc: 0x11223344)
        let nal = Data([0x65, 0xDE, 0xAD, 0xBE, 0xEF]) // small IDR-ish NAL
        let datagrams = packetizer.packetize(nal: nal, timestamp90kHz: 0x00010203, markerOnLast: true)
        XCTAssertEqual(datagrams.count, 1)
        let d = datagrams[0].bytes
        XCTAssertEqual(d[0], 0x80)                    // V=2
        XCTAssertEqual(d[1], 0x80 | 96)               // marker + PT 96
        XCTAssertEqual(Array(d[4..<8]), [0x00, 0x01, 0x02, 0x03]) // timestamp
        XCTAssertEqual(Array(d[8..<12]), [0x11, 0x22, 0x33, 0x44]) // ssrc
        XCTAssertEqual(Array(d[12...]), Array(nal))   // payload is the raw NAL
    }

    func testFUAFragmentationReassembles() {
        let packetizer = RtpPacketizer(maxPayloadSize: 1200)
        var nal = Data([0x65])                        // NAL header: F=0, NRI=3, type=5
        nal.append(Data(repeating: 0xAB, count: 3000))
        let datagrams = packetizer.packetize(nal: nal, timestamp90kHz: 0, markerOnLast: true)
        XCTAssertGreaterThan(datagrams.count, 1)

        let fuIndicator: UInt8 = (0x65 & 0xE0) | 28   // 0x7C
        var reassembled = Data()
        for (i, dg) in datagrams.enumerated() {
            let b = dg.bytes
            XCTAssertEqual(b[12], fuIndicator)
            let fuHeader = b[13]
            XCTAssertEqual(fuHeader & 0x1F, 5)        // original NAL type preserved
            if i == 0 { XCTAssertEqual(fuHeader & 0x80, 0x80) }                 // Start bit
            if i == datagrams.count - 1 {
                XCTAssertEqual(fuHeader & 0x40, 0x40)                           // End bit
                XCTAssertTrue(dg.marker)
            }
            reassembled.append(b[14...])
        }
        XCTAssertEqual(reassembled, nal.dropFirst())  // body minus the NAL header
    }

    func testSequenceNumbersIncrement() {
        let packetizer = RtpPacketizer()
        let a = packetizer.packetize(nal: Data([0x61, 0x00]), timestamp90kHz: 0, markerOnLast: true)[0]
        let b = packetizer.packetize(nal: Data([0x61, 0x00]), timestamp90kHz: 0, markerOnLast: true)[0]
        XCTAssertEqual(b.sequence, a.sequence &+ 1)
    }
}

final class K1GProjectionTests: XCTestCase {

    func testProjectionControlTLVs() {
        XCTAssertEqual(Array(K1GPacket.makeStartNav(seq: 0).suffix(5)),       [0x06, 0x80, 0x00, 0x01, 0x0B])
        XCTAssertEqual(Array(K1GPacket.makeNavContext(seq: 0).suffix(5)),     [0x05, 0x2E, 0x00, 0x01, 0x1E])
        XCTAssertEqual(Array(K1GPacket.makeProjectionOn(seq: 0).suffix(5)),   [0x06, 0x05, 0x00, 0x01, 0x55])
        XCTAssertEqual(Array(K1GPacket.makeProjectionOff(seq: 0).suffix(5)),  [0x06, 0x05, 0x00, 0x01, 0xAA])
        XCTAssertEqual(Array(K1GPacket.makeProjectionFrame(seq: 0).suffix(5)),[0x05, 0x56, 0x00, 0x01, 0x55])
        XCTAssertEqual(Array(K1GPacket.makeProjectionStop(seq: 0).suffix(5)), [0x05, 0x56, 0x00, 0x01, 0xAA])
    }

    func testEmptyListsHasFiveSegments() {
        let p = K1GPacket.makeEmptyLists(seq: 0)
        XCTAssertEqual(Int(p[2]) << 8 | Int(p[3]), 6) // seg_count = 5 + 1
        XCTAssertNotNil(p.range(of: Data([0x05, 0x2F, 0x00, 0x01, 0x00])))
        XCTAssertNotNil(p.range(of: Data([0x05, 0x33, 0x00, 0x01, 0x00])))
    }

    func testRouteCardCarriesTitleAndProjectionFlag() {
        let card = K1GPacket.makeRouteCard(title: "Test", projectionOn: false, seq: 0,
                                           includeManeuverPlaceholders: false)
        XCTAssertEqual(Int(card[0]) << 8 | Int(card[1]), card.count)          // outer_len
        XCTAssertEqual(Int(card[2]) << 8 | Int(card[3]), 4)                   // title + 2 flags + 1
        XCTAssertNotNil(card.range(of: Data("Test".utf8)))                    // ASCII title
        XCTAssertNotNil(card.range(of: Data([0x06, 0x05, 0x00, 0x01, 0xAA]))) // projection off flag
    }

    func testRouteCardFoldsNonASCIITitle() {
        let card = K1GPacket.makeRouteCard(title: "Nižbor", projectionOn: true, seq: 0,
                                           includeManeuverPlaceholders: false)
        XCTAssertNotNil(card.range(of: Data("Nizbor".utf8)))
        XCTAssertNotNil(card.range(of: Data([0x06, 0x05, 0x00, 0x01, 0x55]))) // projection on flag
    }
}

//
//  RtpPacketizer.swift
//  ReTripper
//
//  Pack raw H.264 NALs into RFC 6184 RTP payloads: small NALs ride alone
//  as single-NAL packets, larger ones split into FU-A fragments (type 28).
//  PT 96, one SSRC per session.
//
//  Ported from TripperDash++ (RtpPacketizer) by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import Foundation

/// One RTP/UDP datagram ready for transmission.
struct RtpDatagram: Sendable {
    let bytes: Data
    let marker: Bool
    let sequence: UInt16
}

final class RtpPacketizer: @unchecked Sendable {

    static let payloadType: UInt8 = 96
    let maxPayloadSize: Int
    let ssrc: UInt32
    private var sequence: UInt16

    init(maxPayloadSize: Int = 1200, ssrc: UInt32 = UInt32.random(in: 1..<UInt32.max)) {
        self.maxPayloadSize = maxPayloadSize
        self.ssrc = ssrc
        self.sequence = UInt16.random(in: 0...UInt16.max)
    }

    func packetize(nal: Data, timestamp90kHz: UInt32, markerOnLast: Bool) -> [RtpDatagram] {
        guard !nal.isEmpty else { return [] }
        let bodyBudget = maxPayloadSize - 12
        if nal.count <= bodyBudget {
            let seq = nextSequence()
            let datagram = buildHeader(marker: markerOnLast, sequence: seq, timestamp: timestamp90kHz) + nal
            return [RtpDatagram(bytes: datagram, marker: markerOnLast, sequence: seq)]
        }
        return fragmentFUA(nal: nal, timestamp: timestamp90kHz, markerOnLast: markerOnLast)
    }

    private func fragmentFUA(nal: Data, timestamp: UInt32, markerOnLast: Bool) -> [RtpDatagram] {
        let nalHeader = nal[nal.startIndex]
        let fNri = nalHeader & 0xE0
        let nalType = nalHeader & 0x1F
        let fuIndicator: UInt8 = fNri | 28
        let body = nal.dropFirst()
        let chunkSize = maxPayloadSize - 12 - 2
        var datagrams: [RtpDatagram] = []
        var offset = 0
        let total = body.count
        while offset < total {
            let remaining = total - offset
            let size = min(chunkSize, remaining)
            let isFirst = offset == 0
            let isLast = offset + size == total
            var fuHeader: UInt8 = nalType
            if isFirst { fuHeader |= 0x80 }
            if isLast { fuHeader |= 0x40 }
            let seq = nextSequence()
            var datagram = buildHeader(marker: isLast && markerOnLast, sequence: seq, timestamp: timestamp)
            datagram.append(fuIndicator)
            datagram.append(fuHeader)
            datagram.append(body.subdata(in: (body.startIndex + offset)..<(body.startIndex + offset + size)))
            datagrams.append(RtpDatagram(bytes: datagram, marker: isLast && markerOnLast, sequence: seq))
            offset += size
        }
        return datagrams
    }

    private func buildHeader(marker: Bool, sequence: UInt16, timestamp: UInt32) -> Data {
        var d = Data(count: 12)
        d[0] = 0x80
        d[1] = (marker ? 0x80 : 0x00) | (Self.payloadType & 0x7F)
        d[2] = UInt8((sequence >> 8) & 0xFF)
        d[3] = UInt8(sequence & 0xFF)
        d[4] = UInt8((timestamp >> 24) & 0xFF)
        d[5] = UInt8((timestamp >> 16) & 0xFF)
        d[6] = UInt8((timestamp >> 8) & 0xFF)
        d[7] = UInt8(timestamp & 0xFF)
        d[8] = UInt8((ssrc >> 24) & 0xFF)
        d[9] = UInt8((ssrc >> 16) & 0xFF)
        d[10] = UInt8((ssrc >> 8) & 0xFF)
        d[11] = UInt8(ssrc & 0xFF)
        return d
    }

    private func nextSequence() -> UInt16 {
        let s = sequence
        sequence = sequence &+ 1
        return s
    }
}

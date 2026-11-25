//
//  K1GProjection.swift
//  ReTripper
//
//  K1G control-plane TLVs that drive the dash's navigation-projection
//  surface: enter nav mode, announce a route card, latch projection on/off
//  and signal each new video frame. Needed before (and alongside) the
//  H.264/RTP map stream — the dash won't allocate its video surface on the
//  RTP packets alone.
//
//  Based on TripperDash++ (K1GPacket nav lifecycle) by Martin Kolací
//  (@kolaCZek). PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import Foundation

extension K1GPacket {

    /// NAV_CTX "enter nav context": `05 2E 00 01 1E`.
    static func makeNavContext(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .navInfo, sub: 0x2E, payload: Data([0x1E]))], seq: seq)
    }

    /// EMPTY_LISTS: five `05 2F…33 00 01 00` TLVs (favourites are empty).
    static func makeEmptyLists(seq: UInt8) -> Data {
        let segs = (0x2F...0x33).map { K1GSegment(type: .navInfo, sub: UInt8($0), payload: Data([0x00])) }
        return encode(segments: segs, seq: seq)
    }

    /// START_NAV "begin nav projection": `06 80 00 01 0B`.
    static func makeStartNav(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .status, sub: 0x80, payload: Data([0x0B]))], seq: seq)
    }

    /// PROJ_ON "projection video live": `06 05 00 01 55`.
    static func makeProjectionOn(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .status, sub: 0x05, payload: Data([0x55]))], seq: seq)
    }

    /// PROJ_OFF "projection video stopped": `06 05 00 01 AA`.
    static func makeProjectionOff(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .status, sub: 0x05, payload: Data([0xAA]))], seq: seq)
    }

    /// PROJ_FRAME "a new bitmap landed": `05 56 00 01 55`. Sent once per
    /// H.264 frame so the dash refreshes the projection surface.
    static func makeProjectionFrame(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .navInfo, sub: 0x56, payload: Data([0x55]))], seq: seq)
    }

    /// PROJ_STOP "no more bitmaps": `05 56 00 01 AA`.
    static func makeProjectionStop(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .navInfo, sub: 0x56, payload: Data([0xAA]))], seq: seq)
    }

    /// Route card (`0x007E`) — announces a destination. The dash gates its
    /// nav-decoder surface on this. Byte-for-byte port of TripperDash++'s
    /// `makeRouteCard` (itself a port of better-dash's captured template).
    /// `includeManeuverPlaceholders` keeps the maneuver/distance placeholder
    /// fields (navigation); leave false for a free-ride card.
    static func makeRouteCard(title: String,
                              projectionOn: Bool,
                              seq: UInt8,
                              includeHudFields: Bool = true,
                              includeManeuverPlaceholders: Bool = true) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(seq)

        var navFields: [UInt8] = []
        if includeHudFields {
            var titleBytes = Array(title.dashSafeASCII.utf8.prefix(60))
            titleBytes.append(0)
            navFields += [0x05, 0x01]
            navFields += u16BE(UInt16(titleBytes.count))
            navFields += titleBytes
            if includeManeuverPlaceholders {
                navFields += [
                    0x05, 0x02, 0x00, 0x01, 0x3C,
                    0x05, 0x06, 0x00, 0x01, 0x30,
                    0x05, 0x09, 0x00, 0x02, 0x00, 0x4F,
                    0x05, 0x46, 0x00, 0x01, 0x10,
                    0x05, 0x0A, 0x00, 0x01, 0x55,
                ]
            }
        }
        let projectionFlags: [UInt8] = [
            0x06, 0x05, 0x00, 0x01, projectionOn ? 0x55 : 0xAA,
            0x06, 0x0D, 0x00, 0x01, 0xAA,
        ]
        // seg_count = actual + 1, tracking which blocks above were included.
        let titleSegments = includeHudFields ? 1 : 0
        let maneuverSegments = (includeHudFields && includeManeuverPlaceholders) ? 5 : 0
        let segCount = titleSegments + maneuverSegments + 2 + 1
        body[2] = UInt8((segCount >> 8) & 0xFF)
        body[3] = UInt8(segCount & 0xFF)

        body.append(contentsOf: navFields)
        body.append(contentsOf: projectionFlags)

        let total = UInt16(body.count)
        body[0] = UInt8((total >> 8) & 0xFF)
        body[1] = UInt8(total & 0xFF)
        return body
    }
}

extension String {
    /// Fold to plain printable 7-bit ASCII for the Tripper dash font, which
    /// only renders bare ASCII (diacritics stripped to base letters, other
    /// non-ASCII replaced by a space). No-op for already-ASCII strings.
    var dashSafeASCII: String {
        if utf8.allSatisfy({ $0 < 0x80 }) { return self }
        let folded = folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let out = folded.unicodeScalars.map { scalar -> Character in
            (scalar.value >= 0x20 && scalar.value <= 0x7E) ? Character(scalar) : " "
        }
        return String(out).split(separator: " ").joined(separator: " ")
    }
}

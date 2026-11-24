//
//  K1GProtocol.swift
//  ReTripper
//
//  Wire format for the Royal Enfield "K1G" control-plane protocol spoken
//  between the Tripper Dash TFT and a paired phone over the dash's Wi-Fi.
//
//  ─────────────────────────────────────────────────────────────────────
//  Based on TripperDash++ by Martin Kolací (@kolaCZek)
//  https://github.com/kolaCZek/TripperDashPlusPlus
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//  Non-commercial use only. Protocol reverse-engineered by the community
//  for interoperability with a bike the owner owns. ReTripper never touches
//  firmware, ECU, CAN bus, ABS, throttle or any safety-critical system.
//  ─────────────────────────────────────────────────────────────────────
//
//  Envelope (big-endian):
//      [outer_len: u16]  [seg_count: u16]  [pad: 4×00]
//      [marker: 02 01 00 05]  [magic: "K1G "]  [seq: u8]
//      [segments…]   each segment: [type u8][sub u8][seg_len u16][payload]
//
//  seg_count is emitted as (actual_count + 1); the real dash uses it as a
//  sanity check and drops "naive"-count packets. Inbound packets from the
//  dash omit the marker/magic/seq and start their first TLV at offset 8.
//

import Foundation

enum K1G {

    // MARK: Endpoints
    /// Phone → dash control-plane port.
    static let txPort: UInt16 = 2000
    /// Local bind port for the dash's replies (it answers from its :2002).
    static let rxPort: UInt16 = 2002
    /// Dash port for the H.264 RTP map stream (used in a later phase).
    static let rtpPort: UInt16 = 5000
    /// The dash is the gateway when the phone joins the bike's Wi-Fi.
    static let bikeIPv4 = "192.168.1.1"

    // MARK: Wire constants
    static let magic: [UInt8] = [0x4B, 0x31, 0x47, 0x20]        // "K1G "
    static let icHeaderMarker: [UInt8] = [0x02, 0x01, 0x00, 0x05]

    // MARK: Segment types
    enum SegType: UInt8 {
        case navInfo = 0x05  // phone → dash, nav-info TLVs
        case status  = 0x06  // phone → dash, status TLVs
        case auth    = 0x07  // dash → phone, auth replies
        case session = 0x08  // phone → dash, auth + session payloads
        case button  = 0x09  // dash → phone, joystick / button events
    }
    /// Sub-types under `SegType.auth` (dash → phone).
    enum AuthSub: UInt8 {
        case modulus  = 0x00  // 128-byte RSA-1024 modulus
        case status   = 0x01  // 0x01 = OK, 0x00 = fail
        case exponent = 0x03  // RSA exponent (00 01 00 01)
    }
    /// Sub-types under `SegType.session` (phone → dash).
    enum SessionSub: UInt8 {
        case sessionKey    = 0x00  // RSA-PKCS1v1.5(ssid ‖ aesKey)
        case requestPubkey = 0x04  // "give me your RSA pubkey"
    }

    // MARK: Crypto sizes
    static let aesKeyLength = 32
    static let rsaCiphertextLength = 128

    // MARK: Timing
    static let heartbeatInterval: TimeInterval = 1.0
    static let rxSilenceTimeout: TimeInterval = 10.0
    static let handshakeStepTimeout: TimeInterval = 5.0
    /// The dash's AP comes up well before its control plane answers, so a
    /// fresh connect retries the handshake a few times.
    static let bootRaceMaxAttempts = 4
    static let bootRaceRetryInterval: TimeInterval = 2.0
    /// Gap between packets in the initial burst.
    static let burstPause: TimeInterval = 0.02
}

// MARK: - Segment

struct K1GSegment: Equatable, Sendable {
    let type: UInt8
    let sub: UInt8
    let payload: Data

    init(type: UInt8, sub: UInt8, payload: Data) {
        self.type = type; self.sub = sub; self.payload = payload
    }
    init(type: K1G.SegType, sub: UInt8, payload: Data) {
        self.init(type: type.rawValue, sub: sub, payload: payload)
    }
}

// MARK: - Packet codec

enum K1GPacket {

    static func encode(segments: [K1GSegment], seq: UInt8) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x00])                       // outer_len placeholder
        body.append(contentsOf: u16BE(UInt16(segments.count + 1)))  // seg_count = actual + 1
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])           // pad
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(seq)
        for seg in segments {
            body.append(seg.type)
            body.append(seg.sub)
            body.append(contentsOf: u16BE(UInt16(seg.payload.count)))
            body.append(seg.payload)
        }
        patchOuterLen(&body)
        return body
    }

    /// Split a wire packet into TLV segments. Inbound dash packets omit the
    /// magic and start their first TLV at offset 8, so parse from there.
    static func decode(_ data: Data) -> [K1GSegment] {
        guard data.count >= 8 else { return [] }
        let outerLen = Int(readU16BE(data, at: 0))
        let segCount = Int(readU16BE(data, at: 2))
        let limit = (outerLen > 0 && outerLen <= data.count) ? outerLen : data.count
        var off = 8
        var out: [K1GSegment] = []
        let maxSegments = max(segCount, 64)
        while off + 4 <= limit && out.count < maxSegments {
            let type = byte(data, off)
            let sub = byte(data, off + 1)
            let segLen = Int(readU16BE(data, at: off + 2))
            off += 4
            let end = min(off + segLen, limit)
            let payload = data.subdata(in: index(data, off)..<index(data, end))
            out.append(K1GSegment(type: type, sub: sub, payload: payload))
            off = end
        }
        return out
    }

    /// Replace the rolling-seq byte (after the magic) and refresh outer_len.
    static func patchSeq(_ packet: Data, seq: UInt8) -> Data {
        guard let magic = findMagic(in: packet) else { return packet }
        var out = packet
        out[magic.upperBound] = seq
        patchOuterLen(&out)
        return out
    }

    // MARK: Well-known packets

    static func makeRequestPubkey(seq: UInt8) -> Data {
        encode(segments: [K1GSegment(type: .session,
                                     sub: K1G.SessionSub.requestPubkey.rawValue,
                                     payload: Data([0x01]))], seq: seq)
    }

    static func makeSessionKey(ciphertext: Data, seq: UInt8) -> Data {
        precondition(ciphertext.count == K1G.rsaCiphertextLength,
                     "session key ciphertext must be 128 B (RSA-1024)")
        return encode(segments: [K1GSegment(type: .session,
                                            sub: K1G.SessionSub.sessionKey.rawValue,
                                            payload: ciphertext)], seq: seq)
    }

    /// Announces the phone's name so the dash can label it on its pairing
    /// screen. Fixed header `0021 0002 …`, tail `01 06 0B 00 <len+1> …00`.
    static func makeHostnameAnnounce(hostname: String) -> Data {
        let raw = Array(hostname.utf8.prefix(200))
        var body = Data()
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(contentsOf: [0x01, 0x06, 0x0B, 0x00, UInt8(raw.count + 1)])
        body.append(contentsOf: raw)
        body.append(0x00)
        patchOuterLen(&body)
        return body
    }

    // MARK: Heartbeat status frames (1 Hz keep-alive)

    /// Music-volume bucket TLV (`05 4C`): mute baseline + 10 levels.
    static func musicVolumeTLV(ratio0to1: Double) -> [UInt8] {
        if ratio0to1 <= 0 { return [0x05, 0x4C, 0x00, 0x01, 0x10] }
        return [0x05, 0x4C, 0x00, 0x01, UInt8(0x11 + max(0, min(9, Int(ratio0to1 * 10))))]
    }
    /// Alarm-volume bucket TLV (`05 1B`).
    static func alarmVolumeTLV(ratio0to1: Double) -> [UInt8] {
        if ratio0to1 <= 0 { return [0x05, 0x1B, 0x00, 0x01, 0x10] }
        return [0x05, 0x1B, 0x00, 0x01, UInt8(0x11 + max(0, min(9, Int(ratio0to1 * 10))))]
    }

    /// 0044 heartbeat. `seg_count = 0x000A` is a fixed captured constant —
    /// do not recompute it.
    static func makeHeartbeat0044(seq: UInt8,
                                  fixedTempC: Int = 20,
                                  cellSignal0to255: Int = 160,
                                  batteryPct0to100: Int = 80,
                                  gpsOn: Bool = true,
                                  charging: Bool = false,
                                  signalPresent: Bool = true,
                                  musicRatio0to1: Double = 0.3,
                                  navDistanceRounded: Int = 0,
                                  alarmRatio0to1: Double = 0.3) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(seq)
        body.append(contentsOf: [0x06, 0x08, 0x00, 0x01, UInt8(cellSignal0to255 & 0xFF)])
        body.append(contentsOf: [0x06, 0x10, 0x00, 0x01, UInt8((fixedTempC + 40) & 0xFF)])
        body.append(contentsOf: [0x06, 0x03, 0x00, 0x01, gpsOn ? 0x55 : 0xAA])
        body.append(contentsOf: [0x06, 0x04, 0x00, 0x01, UInt8((batteryPct0to100 + 100) & 0xFF)])
        body.append(contentsOf: [0x06, 0x0F, 0x00, 0x01, charging ? 0x55 : 0xAA])
        body.append(contentsOf: [0x06, 0x01, 0x00, 0x01, signalPresent ? 0x01 : 0x00])
        body.append(contentsOf: musicVolumeTLV(ratio0to1: musicRatio0to1))
        body.append(contentsOf: [0x05, 0x2D, 0x00, 0x02,
                                 UInt8((navDistanceRounded >> 8) & 0xFF),
                                 UInt8(navDistanceRounded & 0xFF)])
        body.append(contentsOf: alarmVolumeTLV(ratio0to1: alarmRatio0to1))
        patchOuterLen(&body)
        return body
    }

    /// 0030 trimmed metadata frame. `seg_count = 0x0006`.
    static func makeMetadata0030(seq: UInt8,
                                 cellSignal0to255: Int = 160,
                                 musicRatio0to1: Double = 0.3,
                                 navDistanceRounded: Int = 0,
                                 alarmRatio0to1: Double = 0.3) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(seq)
        body.append(contentsOf: [0x06, 0x08, 0x00, 0x01, UInt8(cellSignal0to255 & 0xFF)])
        body.append(contentsOf: musicVolumeTLV(ratio0to1: musicRatio0to1))
        body.append(contentsOf: [0x05, 0x2D, 0x00, 0x02,
                                 UInt8((navDistanceRounded >> 8) & 0xFF),
                                 UInt8(navDistanceRounded & 0xFF)])
        body.append(contentsOf: alarmVolumeTLV(ratio0to1: alarmRatio0to1))
        patchOuterLen(&body)
        return body
    }

    // MARK: Helpers

    static func u16BE(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    private static func patchOuterLen(_ body: inout Data) {
        let total = UInt16(body.count)
        body[body.startIndex] = UInt8((total >> 8) & 0xFF)
        body[body.index(body.startIndex, offsetBy: 1)] = UInt8(total & 0xFF)
    }
    private static func index(_ d: Data, _ o: Int) -> Data.Index { d.index(d.startIndex, offsetBy: o) }
    private static func byte(_ d: Data, _ o: Int) -> UInt8 { d[index(d, o)] }
    private static func readU16BE(_ d: Data, at o: Int) -> UInt16 {
        (UInt16(byte(d, o)) << 8) | UInt16(byte(d, o + 1))
    }
    private static func findMagic(in data: Data) -> Range<Int>? {
        guard let r = data.range(of: Data(K1G.magic)) else { return nil }
        return data.distance(from: data.startIndex, to: r.lowerBound)
             ..< data.distance(from: data.startIndex, to: r.upperBound)
    }
}

// MARK: - Rolling sequence

/// Thread-safe monotonic 0…255 counter (wraps). A fresh connection resets it.
final class RollingSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8
    init(start: UInt8 = 0) { value = start }
    func consume() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        let v = value; value = value &+ 1; return v
    }
    func reset(to start: UInt8 = 0) {
        lock.lock(); defer { lock.unlock() }
        value = start
    }
}

// MARK: - Initial burst

/// The exact 9-packet discovery burst the real Tripper app sends on connect.
/// If any are missing or out of order, the dash stays on its pairing screen
/// and the RSA handshake never starts. Source: TripperDash++ `InitialBurst`.
enum InitialBurst {

    static func packets(hostname: String, seq: RollingSeq) -> [Data] {
        let p1 = K1GPacket.makeRequestPubkey(seq: seq.consume())
        let p2 = K1GPacket.makeHostnameAnnounce(hostname: hostname)
        let p3 = makePacket3SetClock(now: Date())
        let p4 = hexToData("0016000200000000020100054b314720030557000155")
        let p5 = hexToData("0016000200000000020100054b3147200405560001aa")
        let p6 = hexToData("0016000200000000020100054b3147200506050001aa")
        let p7 = hexToData("0016000200000000020100054b3147200605170001aa")
        let p8 = hexToData("001d000200000000020100054b314720080a020008aa55000000000000")
        // p9: verbatim initial 0044 status frame. 10 TLVs, seg_count=0x000A.
        // Must be byte-exact — a generated frame is dropped by the real dash.
        let p9 = hexToData(
            "0044000a00000000020100054b3147200906080001ff060300015506040001a2" +
            "060f0001aa0601000101054c000113052d00020000051b0001190521000132054d000132")
        return [p1, p2, p3, p4, p5, p6, p7, p8, p9]
    }

    /// Packet 3 carries the wall-clock set-time TLV `06 06` with three
    /// **binary** bytes (hour, minute, second). The dash adopts it as its RTC.
    static func makePacket3SetClock(now: Date) -> Data {
        let c = Calendar.current
        return makePacket3SetClock(hour: UInt8(c.component(.hour, from: now) & 0xFF),
                                   minute: UInt8(c.component(.minute, from: now) & 0xFF),
                                   second: UInt8(c.component(.second, from: now) & 0xFF))
    }
    static func makePacket3SetClock(hour: UInt8, minute: UInt8, second: UInt8) -> Data {
        var p = Data()
        p.append(contentsOf: [0x00, 0x18, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
                              0x02, 0x01, 0x00, 0x05, 0x4B, 0x31, 0x47, 0x20, 0x02])
        p.append(contentsOf: [0x06, 0x06, 0x00, 0x03])
        p.append(hour); p.append(minute); p.append(second)
        return p
    }

    static func hexToData(_ hex: String) -> Data {
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }
}

// MARK: - Phone telemetry for the heartbeat

/// Snapshot the heartbeat reports to the dash once a second.
struct PhoneTelemetry: Sendable, Equatable {
    var cellSignal0to255: Int
    var batteryPct0to100: Int
    var gpsOn: Bool
    var charging: Bool
    var signalPresent: Bool

    /// "Sane phone client" defaults so the link never drops for want of real
    /// data — the dash keys its keep-alive on the frame arriving, not its
    /// contents.
    static let placeholder = PhoneTelemetry(cellSignal0to255: 160, batteryPct0to100: 80,
                                            gpsOn: true, charging: false, signalPresent: true)
}

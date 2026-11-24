//
//  DashLinkTests.swift
//  ReTripperTests
//
//  Byte-level tests for the K1G protocol codec, the initial burst, the
//  heartbeat frames and the RSA session handshake. The live socket /
//  handshake / heartbeat can only be verified against a real dash.
//

import XCTest
import Security
@testable import ReTripper

final class K1GCodecTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let segments = [
            K1GSegment(type: .session, sub: 0x04, payload: Data([0x01])),
            K1GSegment(type: .status, sub: 0x08, payload: Data([0xAB, 0xCD])),
        ]
        let packet = K1GPacket.encode(segments: segments, seq: 0x07)
        // outer_len equals the real size.
        XCTAssertEqual(Int(packet[0]) << 8 | Int(packet[1]), packet.count)
        // seg_count = actual + 1.
        XCTAssertEqual(Int(packet[2]) << 8 | Int(packet[3]), segments.count + 1)
        // magic present.
        XCTAssertNotNil(packet.range(of: Data(K1G.magic)))
        let decoded = K1GPacket.decode(packet)
        XCTAssertEqual(decoded, segments)
    }

    func testRequestPubkeyExactBytes() {
        let expected = Data([
            0x00, 0x16, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x01, 0x00, 0x05, 0x4B, 0x31, 0x47, 0x20,
            0x00, 0x08, 0x04, 0x00, 0x01, 0x01,
        ])
        XCTAssertEqual(K1GPacket.makeRequestPubkey(seq: 0x00), expected)
    }

    func testPatchSeqChangesOnlyTheSeqByte() {
        let original = K1GPacket.makeRequestPubkey(seq: 0x00)
        let patched = K1GPacket.patchSeq(original, seq: 0x42)
        XCTAssertNotEqual(original, patched)
        XCTAssertEqual(K1GPacket.patchSeq(patched, seq: 0x00), original)
    }

    func testDecodesInboundModulusReplyFromOffsetEight() {
        // Inbound dash packets omit the magic; first TLV starts at offset 8.
        let modulus = Data(repeating: 0xAA, count: 128)
        var packet = Data([0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]) // header
        packet.append(contentsOf: [0x07, 0x00])                             // auth / modulus
        packet.append(contentsOf: K1GPacket.u16BE(128))
        packet.append(modulus)
        // fix outer_len
        packet[0] = UInt8(packet.count >> 8); packet[1] = UInt8(packet.count & 0xFF)
        let segs = K1GPacket.decode(packet)
        XCTAssertEqual(segs.first?.type, 0x07)
        XCTAssertEqual(segs.first?.sub, 0x00)
        XCTAssertEqual(segs.first?.payload, modulus)
    }
}

final class K1GHeartbeatTests: XCTestCase {
    func testHeartbeat0044ShapeAndBatteryEncoding() {
        let hb = K1GPacket.makeHeartbeat0044(seq: 0x09, batteryPct0to100: 62)
        XCTAssertEqual(Array(hb.prefix(4)), [0x00, UInt8(hb.count), 0x00, 0x0A]) // outer_len, seg_count
        XCTAssertNotNil(hb.range(of: Data(K1G.magic)))
        // Battery payload is (pct + 100): 62 → 0xA2.
        XCTAssertNotNil(hb.range(of: Data([0x06, 0x04, 0x00, 0x01, 0xA2])))
    }

    func testMetadata0030SegCount() {
        let md = K1GPacket.makeMetadata0030(seq: 0x00)
        XCTAssertEqual(Int(md[2]) << 8 | Int(md[3]), 6)
        XCTAssertEqual(Int(md[0]) << 8 | Int(md[1]), md.count)
    }
}

final class InitialBurstTests: XCTestCase {
    func testBurstIsNinePacketsStartingWithRequestPubkey() {
        let seq = RollingSeq()
        let packets = InitialBurst.packets(hostname: "ReTripper", seq: seq)
        XCTAssertEqual(packets.count, 9)
        XCTAssertEqual(Array(packets[0].suffix(5)), [0x08, 0x04, 0x00, 0x01, 0x01]) // REQUEST_PUBKEY tail
        XCTAssertEqual(Array(packets[8].prefix(4)), [0x00, 0x44, 0x00, 0x0A])       // verbatim 0044
    }

    func testClockPacketUsesBinaryTimeBytes() {
        let p = InitialBurst.makePacket3SetClock(hour: 20, minute: 8, second: 5)
        XCTAssertEqual(Array(p.suffix(7)), [0x06, 0x06, 0x00, 0x03, 20, 8, 5])
    }
}

final class DashHandshakeTests: XCTestCase {

    func testAuthOKDetection() {
        XCTAssertTrue(DashRsaHandshake.isAuthOK([K1GSegment(type: .auth, sub: 0x01, payload: Data([0x01]))]))
        XCTAssertFalse(DashRsaHandshake.isAuthOK([K1GSegment(type: .auth, sub: 0x01, payload: Data([0x00]))]))
        XCTAssertFalse(DashRsaHandshake.isAuthOK([K1GSegment(type: .status, sub: 0x01, payload: Data([0x01]))]))
    }

    func testModulusAndExponentExtraction() {
        let m = Data(repeating: 0x11, count: 128)
        let e = Data([0x01, 0x00, 0x01])
        let segs = [
            K1GSegment(type: .auth, sub: 0x00, payload: m),
            K1GSegment(type: .auth, sub: 0x03, payload: e),
        ]
        let found = DashRsaHandshake.modulusAndExponent(from: segs)
        XCTAssertEqual(found?.modulus, m)
        XCTAssertEqual(found?.exponent, e)
        XCTAssertNil(DashRsaHandshake.modulusAndExponent(from: [segs[0]]))
    }

    /// Full crypto chain: build the dash's public key from raw modulus +
    /// exponent, encrypt (ssid ‖ aesKey), and decrypt with the matching
    /// private key. Validates the PKCS#1 ASN.1 re-encoding and PKCS1v1.5.
    func testSessionKeyEncryptsAndDecryptsRoundTrip() throws {
        let priv = try makeRSAPrivateKey(bits: 1024)
        let pub = SecKeyCopyPublicKey(priv)!
        let (modulus, exponent) = try rawModulusExponent(fromPublic: pub)

        let dashKey = try DashRsaHandshake.makePublicKey(modulus: modulus, exponent: exponent)
        let aesKey = try DashRsaHandshake.makeAesKey()
        XCTAssertEqual(aesKey.count, K1G.aesKeyLength)
        let ssid = "RE_MVWW_260317"
        let ciphertext = try DashRsaHandshake.encryptSessionKey(ssid: ssid, aesKey: aesKey,
                                                               dashPublicKey: dashKey)
        XCTAssertEqual(ciphertext.count, K1G.rsaCiphertextLength)

        var error: Unmanaged<CFError>?
        let plain = SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1,
                                              ciphertext as CFData, &error) as Data?
        XCTAssertNil(error)
        var expected = Data(ssid.utf8); expected.append(aesKey)
        XCTAssertEqual(plain, expected)
    }

    // MARK: helpers

    private func makeRSAPrivateKey(bits: Int) throws -> SecKey {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    /// Parse the PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus, exponent }`
    /// external representation into raw big-endian integers (leading zero
    /// stripped so the modulus is exactly 128 bytes, as the dash sends).
    private func rawModulusExponent(fromPublic key: SecKey) throws -> (Data, Data) {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        var i = der.startIndex
        func readLen() -> Int {
            var b = Int(der[i]); i = der.index(after: i)
            if b < 0x80 { return b }
            let n = b & 0x7F; var len = 0
            for _ in 0..<n { len = (len << 8) | Int(der[i]); i = der.index(after: i) }
            return len
        }
        XCTAssertEqual(der[i], 0x30); i = der.index(after: i); _ = readLen() // SEQUENCE
        func readInt() -> Data {
            XCTAssertEqual(der[i], 0x02); i = der.index(after: i)
            let len = readLen()
            var v = der.subdata(in: i..<der.index(i, offsetBy: len))
            i = der.index(i, offsetBy: len)
            while v.count > 1 && v.first == 0x00 { v = v.dropFirst() }
            return v
        }
        let modulus = readInt()
        let exponent = readInt()
        return (modulus, exponent)
    }
}

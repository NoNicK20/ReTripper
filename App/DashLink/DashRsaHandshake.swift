//
//  DashRsaHandshake.swift
//  ReTripper
//
//  Phone side of the K1G RSA-1024 / PKCS1v1.5 handshake:
//    1. send the initial burst (REQUEST_PUBKEY first)
//    2. dash replies with modulus (07 00) + exponent (07 03)
//    3. encrypt (ssid ‖ aesKey) under the dash's pubkey → SESSION_KEY (08 00)
//    4. dash replies 07 01 01 (auth OK)
//
//  Based on TripperDash++ (RsaHandshake) by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import Foundation
import Security

enum DashHandshakeError: Error, LocalizedError, Equatable {
    case modulusWrongLength(Int)
    case secKeyCreationFailed
    case encryptionFailed(String)
    case missingSegment(String)
    case noReplyAtAll
    case authNotReady
    case randomBytesFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .modulusWrongLength(let n): return "Dash sent an RSA key of \(n) bytes (expected 128)."
        case .secKeyCreationFailed: return "Could not build the dash's encryption key."
        case .encryptionFailed(let s): return "Encrypting the session key failed: \(s)"
        case .missingSegment(let s): return "The dash's reply was missing its \(s)."
        case .noReplyAtAll: return "The dash didn't answer. It may still be starting up."
        case .authNotReady: return "The dash is busy and hasn't confirmed pairing yet."
        case .randomBytesFailed(let s): return "Could not generate a session key (status \(s))."
        }
    }
}

struct DashHandshakeOutcome: Sendable {
    let aesKey: Data
    let ssid: String
}

enum DashRsaHandshake {

    /// Build a `SecKey` from the modulus (`07 00`) + exponent (`07 03`).
    static func makePublicKey(modulus: Data, exponent: Data) throws -> SecKey {
        guard modulus.count == K1G.rsaCiphertextLength else {
            throw DashHandshakeError.modulusWrongLength(modulus.count)
        }
        let der = encodePKCS1RSAPublicKey(modulus: modulus, exponent: exponent)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            error?.release()
            throw DashHandshakeError.secKeyCreationFailed
        }
        return key
    }

    static func makeAesKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: K1G.aesKeyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw DashHandshakeError.randomBytesFailed(status) }
        return Data(bytes)
    }

    /// PKCS1v1.5-encrypt `ssid_utf8 ‖ aesKey` under the dash's public key.
    /// Returns exactly 128 bytes.
    static func encryptSessionKey(ssid: String, aesKey: Data, dashPublicKey: SecKey) throws -> Data {
        precondition(aesKey.count == K1G.aesKeyLength)
        var plaintext = Data()
        plaintext.append(contentsOf: ssid.utf8)
        plaintext.append(aesKey)
        var error: Unmanaged<CFError>?
        guard let ct = SecKeyCreateEncryptedData(dashPublicKey, .rsaEncryptionPKCS1,
                                                 plaintext as CFData, &error) else {
            let message = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown"
            throw DashHandshakeError.encryptionFailed(message)
        }
        return ct as Data
    }

    /// Detect the auth-OK reply (`07 01 01`).
    static func isAuthOK(_ segments: [K1GSegment]) -> Bool {
        segments.contains {
            $0.type == K1G.SegType.auth.rawValue
            && $0.sub == K1G.AuthSub.status.rawValue
            && $0.payload == Data([0x01])
        }
    }

    /// Pull the modulus (`07 00`) and exponent (`07 03`) out of collected
    /// reply segments, if both are present.
    static func modulusAndExponent(from segments: [K1GSegment]) -> (modulus: Data, exponent: Data)? {
        let modulus = segments.first {
            $0.type == K1G.SegType.auth.rawValue && $0.sub == K1G.AuthSub.modulus.rawValue
        }?.payload
        let exponent = segments.first {
            $0.type == K1G.SegType.auth.rawValue && $0.sub == K1G.AuthSub.exponent.rawValue
        }?.payload
        guard let m = modulus, let e = exponent else { return nil }
        return (m, e)
    }

    // MARK: - PKCS#1 RSAPublicKey DER

    private static func encodePKCS1RSAPublicKey(modulus: Data, exponent: Data) -> Data {
        var inner = Data()
        inner.append(encodeASN1Integer(modulus))
        inner.append(encodeASN1Integer(exponent))
        return wrapSequence(inner)
    }

    private static func encodeASN1Integer(_ raw: Data) -> Data {
        var body = raw
        while body.count > 1 && body[body.startIndex] == 0x00 {
            body = body.subdata(in: body.index(after: body.startIndex)..<body.endIndex)
        }
        if let first = body.first, first & 0x80 != 0 {
            var padded = Data([0x00]); padded.append(body); body = padded
        }
        var out = Data([0x02])
        out.append(encodeLength(body.count))
        out.append(body)
        return out
    }

    private static func wrapSequence(_ inner: Data) -> Data {
        var out = Data([0x30])
        out.append(encodeLength(inner.count))
        out.append(inner)
        return out
    }

    private static func encodeLength(_ len: Int) -> Data {
        if len < 0x80 { return Data([UInt8(len)]) }
        var bytes: [UInt8] = []
        var n = len
        while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
        var out = Data([UInt8(0x80 | bytes.count)])
        out.append(contentsOf: bytes)
        return out
    }
}

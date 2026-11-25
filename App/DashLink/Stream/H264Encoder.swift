//
//  H264Encoder.swift
//  ReTripper
//
//  Hardware H.264 encoder on VideoToolbox. Baseline profile, 512 kbps,
//  one keyframe per second, no burst headroom — the stream shape the
//  Tripper dash's firmware decoder accepts. Emits raw NALs (SPS/PPS before
//  each IDR) to the RTP packetizer.
//
//  Ported from TripperDash++ (H264Encoder) by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os.log

/// One H.264 NAL unit emitted by the encoder (raw — no start code, no
/// length prefix).
struct EncodedNAL: @unchecked Sendable {
    enum Kind: Sendable {
        case sps, pps, idr, nonIDR
        case other(UInt8)
    }
    let kind: Kind
    let bytes: Data
    let timestamp: CMTime
    let isKeyframe: Bool

    var nalType: UInt8 { bytes.first.map { $0 & 0x1F } ?? 0 }
}

final class H264Encoder {

    let width: Int32
    let height: Int32
    let fps: Int32
    let bitrate: Int32
    let keyframeInterval: Int32

    var onNAL: ((EncodedNAL) -> Void)?

    private let log = Logger(subsystem: "com.nonick20.retripper", category: "H264")
    private var session: VTCompressionSession?
    private var lastFormatDescription: CMFormatDescription?
    private var pendingForceKeyframe = false
    private var consecutiveEncodeErrors = 0

    init(width: Int32 = 526, height: Int32 = 300, fps: Int32 = 4,
         bitrate: Int32 = 512_000, keyframeInterval: Int32? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval ?? fps
    }

    deinit { stop() }

    func start() throws {
        guard session == nil else { return }
        try createSession()
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        lastFormatDescription = nil
        pendingForceKeyframe = false
        consecutiveEncodeErrors = 0
    }

    func forceKeyframeNext() { pendingForceKeyframe = true }

    private func createSession() throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            throw EncoderError.sessionCreateFailed(status)
        }
        self.session = session

        let props: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: Double(keyframeInterval) / Double(fps))),
            (kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray),
        ]
        for (key, value) in props {
            let r = VTSessionSetProperty(session, key: key, value: value)
            if r != noErr { log.warning("VTSessionSetProperty \(key as String, privacy: .public) failed: \(r)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        lastFormatDescription = nil
        pendingForceKeyframe = true
    }

    private func rebuildSession() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            self.session = nil
        }
        do { try createSession() }
        catch { log.error("H264Encoder session rebuild failed: \(String(describing: error), privacy: .public)") }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        var frameProperties: [CFString: Any] = [:]
        if pendingForceKeyframe {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue
            pendingForceKeyframe = false
        }
        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: fps),
            frameProperties: frameProperties as CFDictionary, infoFlagsOut: &infoFlags
        ) { [weak self] status, _, sampleBuffer in
            self?.handleEncoded(status: status, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            consecutiveEncodeErrors += 1
            if status == -12903 || status == -12902 {
                if consecutiveEncodeErrors == 1 { log.notice("VTCompressionSessionEncodeFrame failed: \(status) — rebuilding") }
                rebuildSession()
            } else if consecutiveEncodeErrors == 1 {
                log.error("VTCompressionSessionEncodeFrame failed: \(status)")
            }
        } else {
            consecutiveEncodeErrors = 0
        }
    }

    private func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKey: Bool
        if let first = attachments?.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        } else { isKey = true }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            emitParameterSets(from: fmt, at: pts)
            lastFormatDescription = fmt
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let bbStatus = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard bbStatus == kCMBlockBufferNoErr, let dataPointer else { return }

        let base = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 < length {
            let nalLength = Int(UInt32(base[offset]) << 24 | UInt32(base[offset + 1]) << 16 |
                                UInt32(base[offset + 2]) << 8 | UInt32(base[offset + 3]))
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            let bytes = Data(bytes: base.advanced(by: offset), count: nalLength)
            offset += nalLength
            let nalType = bytes.first.map { $0 & 0x1F } ?? 0
            let kind: EncodedNAL.Kind
            switch nalType {
            case 5: kind = .idr
            case 1: kind = .nonIDR
            case 7: kind = .sps
            case 8: kind = .pps
            default: kind = .other(nalType)
            }
            onNAL?(EncodedNAL(kind: kind, bytes: bytes, timestamp: pts, isKeyframe: isKey))
        }
    }

    private func emitParameterSets(from fmt: CMFormatDescription, at pts: CMTime) {
        var spsCount = 0
        _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)
        for i in 0..<spsCount {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard s == noErr, let ptr else { continue }
            let bytes = Data(bytes: ptr, count: size)
            let nalType = bytes.first.map { $0 & 0x1F } ?? 0
            let kind: EncodedNAL.Kind = (nalType == 7) ? .sps : (nalType == 8) ? .pps : .other(nalType)
            onNAL?(EncodedNAL(kind: kind, bytes: bytes, timestamp: pts, isKeyframe: true))
        }
    }

    enum EncoderError: Error { case sessionCreateFailed(OSStatus) }
}

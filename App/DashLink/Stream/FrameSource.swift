//
//  FrameSource.swift
//  ReTripper
//
//  Pluggable producer of pixel buffers for the H.264 streamer. The map
//  renderer (a later stage) is one implementation; a test pattern is
//  another. Frames are 526×300 BGRA — the native Tripper TFT resolution.
//
//  Based on TripperDash++ (FrameSource) by Martin Kolací (@kolaCZek).
//  PolyForm Noncommercial License 1.0.0 — see LICENSE / CREDITS.md.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

protocol FrameSource: AnyObject {
    var frameSize: CGSize { get }
    var targetFps: Int { get }

    /// Begin producing frames; the callback fires on the source's own
    /// thread. Implementations must not block on it.
    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void)
    func stop()
}

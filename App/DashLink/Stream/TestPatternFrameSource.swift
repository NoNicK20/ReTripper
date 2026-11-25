//
//  TestPatternFrameSource.swift
//  ReTripper
//
//  A simple animated 526×300 frame source so the whole video pipeline
//  (encode → RTP → dash) can be exercised and seen on the screen before
//  the real Google-map renderer exists. Draws the ReTripper wordmark, a
//  moving marker and a frame counter on pure black.
//

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import QuartzCore

final class TestPatternFrameSource: FrameSource {

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 4

    private var timer: Timer?
    private var frameIndex: Int64 = 0
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private let apexRed = CGColor(red: 0.86, green: 0.08, blue: 0.09, alpha: 1)

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
        frameIndex = 0
        let interval = 1.0 / Double(targetFps)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.renderFrame()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        onFrame = nil
    }

    private func renderFrame() {
        guard let buffer = makePixelBuffer() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let w = Int(frameSize.width), h = Int(frameSize.height)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        // Background.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Apex-red header bar.
        ctx.setFillColor(apexRed)
        ctx.fill(CGRect(x: 0, y: h - 46, width: w, height: 46))

        // Moving marker — sweeps left→right so a frozen frame is obvious.
        let phase = Double(frameIndex % Int64(targetFps * 4)) / Double(targetFps * 4)
        let x = 20 + phase * Double(w - 40)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x - 10, y: Double(h) / 2 - 10, width: 20, height: 20))

        drawText("ReTripper", at: CGPoint(x: 16, y: Double(h) - 34), size: 26, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1), in: ctx)
        drawText("dash video test — frame \(frameIndex)", at: CGPoint(x: 16, y: 20), size: 16,
                 color: CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1), in: ctx)

        let pts = CMTime(value: frameIndex, timescale: Int32(targetFps))
        frameIndex += 1
        onFrame?(buffer, pts)
    }

    private func drawText(_ string: String, at point: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        // CTLineDraw uses the context fill colour when runs carry none.
        ctx.setFillColor(color)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(frameSize.width), Int(frameSize.height),
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return buffer
    }
}

//
//  GoogleMapFrameSource.swift
//  ReTripper
//
//  The real dash map: renders 526×300 frames from Google Map Tiles centred
//  on the rider, north-up, with a heading chevron, and feeds them to the
//  H.264 streamer. Tiles are fetched and cached asynchronously; each 4 fps
//  frame draws from whatever tiles are in hand.
//
//  With no Google Maps key (or Map Tiles API not enabled) it renders a
//  "map not configured" frame instead of any other provider's map.
//
//  Uses the streaming pipeline and never modifies the motorcycle.
//

import CoreGraphics
import CoreLocation
import CoreMedia
import CoreText
import CoreVideo
import Foundation

final class GoogleMapFrameSource: NSObject, FrameSource, CLLocationManagerDelegate {

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 4
    var zoom = 16

    private let fetcher: GoogleTileFetcher
    private let locationManager = CLLocationManager()
    private var timer: Timer?
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private var frameIndex: Int64 = 0

    private var coordinate: CLLocationCoordinate2D?
    private var headingDegrees: Double = 0
    private var tileMirror: [GoogleTileFetcher.TileKey: CGImage] = [:]
    private var refreshing = false

    private let apexRed = CGColor(red: 0.86, green: 0.08, blue: 0.09, alpha: 1)

    init(fetcher: GoogleTileFetcher = GoogleTileFetcher()) {
        self.fetcher = fetcher
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
        frameIndex = 0
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { locationManager.startUpdatingHeading() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(targetFps), repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        onFrame = nil
    }

    // MARK: - Location

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        coordinate = loc.coordinate
        if loc.course >= 0 && loc.speed > 2 { headingDegrees = loc.course }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        if h >= 0 { headingDegrees = h }
    }

    // MARK: - Render loop

    private func tick() {
        renderFrame()
        kickTileRefresh()
    }

    private func kickTileRefresh() {
        guard let coord = coordinate, !refreshing else { return }
        let keys = tileKeys(center: coord)
        refreshing = true
        let fetcher = self.fetcher
        Task { [weak self] in
            await fetcher.prefetch(keys)
            let images = await fetcher.images(keys)
            await MainActor.run { [weak self] in
                self?.tileMirror = images
                self?.refreshing = false
            }
        }
    }

    /// Tile keys covering the 526×300 window around `center` (plus a ring).
    private func tileKeys(center: CLLocationCoordinate2D) -> [GoogleTileFetcher.TileKey] {
        let c = WebMercator.worldPixel(center, zoom: zoom)
        let originX = c.x - Double(frameSize.width) / 2
        let originY = c.y - Double(frameSize.height) / 2
        let minTX = Int(floor(originX / WebMercator.tileSize)) - 1
        let maxTX = Int(floor((originX + Double(frameSize.width)) / WebMercator.tileSize)) + 1
        let minTY = Int(floor(originY / WebMercator.tileSize)) - 1
        let maxTY = Int(floor((originY + Double(frameSize.height)) / WebMercator.tileSize)) + 1
        var keys: [GoogleTileFetcher.TileKey] = []
        for ty in minTY...maxTY {
            for tx in minTX...maxTX {
                if let w = WebMercator.wrap(x: tx, y: ty, zoom: zoom) {
                    keys.append(.init(z: zoom, x: w.x, y: w.y))
                }
            }
        }
        return keys
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

        // Dark background.
        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        guard let coord = coordinate else {
            drawCentreText("Waiting for GPS…", in: ctx, size: CGSize(width: w, height: h))
            emit(buffer)
            return
        }

        // Draw tiles (north-up). Context is y-up; flip each tile to draw upright.
        let c = WebMercator.worldPixel(coord, zoom: zoom)
        let originX = c.x - Double(w) / 2         // world px at screen-left
        let originY = c.y - Double(h) / 2         // world px at screen-top (north)
        let ts = WebMercator.tileSize
        let minTX = Int(floor(originX / ts)), maxTX = Int(floor((originX + Double(w)) / ts))
        let minTY = Int(floor(originY / ts)), maxTY = Int(floor((originY + Double(h)) / ts))
        var anyTile = false
        for ty in minTY...maxTY {
            for tx in minTX...maxTX {
                guard let wk = WebMercator.wrap(x: tx, y: ty, zoom: zoom),
                      let img = tileMirror[.init(z: zoom, x: wk.x, y: wk.y)] else { continue }
                anyTile = true
                let sx = Double(tx) * ts - originX                    // screen x, left→right
                let imgTopScreen = Double(ty) * ts - originY          // screen y from top (north)
                ctx.saveGState()
                ctx.translateBy(x: sx, y: Double(h) - imgTopScreen)   // tile top-left in y-up ctx
                ctx.scaleBy(x: 1, y: -1)                              // draw image upright
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: ts, height: ts))
                ctx.restoreGState()
            }
        }

        if !anyTile {
            drawCentreText("Loading map… (needs Map Tiles API + a Google Maps key)",
                           in: ctx, size: CGSize(width: w, height: h))
        } else {
            drawRiderMarker(in: ctx, center: CGPoint(x: Double(w) / 2, y: Double(h) / 2))
        }
        emit(buffer)
    }

    private func drawRiderMarker(in ctx: CGContext, center: CGPoint) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -headingDegrees * .pi / 180.0)   // y-up ctx: clockwise heading = negative
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: 16))              // apex points "up" (north when heading 0)
        ctx.addLine(to: CGPoint(x: -11, y: -12))
        ctx.addLine(to: CGPoint(x: 0, y: -5))
        ctx.addLine(to: CGPoint(x: 11, y: -12))
        ctx.closePath()
        ctx.setFillColor(apexRed)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawCentreText(_ string: String, in ctx: CGContext, size: CGSize) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        ctx.textPosition = CGPoint(x: (size.width - bounds.width) / 2, y: size.height / 2 - 6)
        CTLineDraw(line, ctx)
    }

    private func emit(_ buffer: CVPixelBuffer) {
        let pts = CMTime(value: frameIndex, timescale: Int32(targetFps))
        frameIndex += 1
        onFrame?(buffer, pts)
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

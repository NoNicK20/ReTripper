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
    /// Heading-up (map rotates so travel direction is up). false = north-up.
    var headingUp = true

    /// World-pixel radius that must be covered so the rotated 526×300 frame
    /// never shows a corner gap, plus a tile of margin.
    private var coverRadius: Double {
        (sqrt(pow(Double(frameSize.width), 2) + pow(Double(frameSize.height), 2)) / 2) + WebMercator.tileSize
    }

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

    /// Range of tile indices covering a `coverRadius` square around the rider.
    private func tileRange(center c: CGPoint) -> (minTX: Int, maxTX: Int, minTY: Int, maxTY: Int) {
        let ts = WebMercator.tileSize
        return (Int(floor((c.x - coverRadius) / ts)), Int(floor((c.x + coverRadius) / ts)),
                Int(floor((c.y - coverRadius) / ts)), Int(floor((c.y + coverRadius) / ts)))
    }

    /// Tile keys covering the rotated window around `center`.
    private func tileKeys(center: CLLocationCoordinate2D) -> [GoogleTileFetcher.TileKey] {
        let c = WebMercator.worldPixel(center, zoom: zoom)
        let r = tileRange(center: c)
        var keys: [GoogleTileFetcher.TileKey] = []
        for ty in r.minTY...r.maxTY {
            for tx in r.minTX...r.maxTX {
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

        // Context is y-up; "up" (+y) is the top of the frame. The rider sits
        // at the frame centre. For heading-up, rotate the map CCW by the
        // heading so the travel direction points up; the rider chevron then
        // stays pointing up. For north-up, the map isn't rotated and the
        // chevron rotates to the heading instead.
        let c = WebMercator.worldPixel(coord, zoom: zoom)
        let originX = c.x - Double(w) / 2         // world px at screen-left (pre-rotation)
        let originY = c.y - Double(h) / 2         // world px at screen-top
        let ts = WebMercator.tileSize
        let r = tileRange(center: c)

        ctx.saveGState()
        if headingUp {
            ctx.translateBy(x: Double(w) / 2, y: Double(h) / 2)
            ctx.rotate(by: headingDegrees * .pi / 180.0)   // y-up CCW = heading-up
            ctx.translateBy(x: -Double(w) / 2, y: -Double(h) / 2)
        }
        var anyTile = false
        for ty in r.minTY...r.maxTY {
            for tx in r.minTX...r.maxTX {
                guard let wk = WebMercator.wrap(x: tx, y: ty, zoom: zoom),
                      let img = tileMirror[.init(z: zoom, x: wk.x, y: wk.y)] else { continue }
                anyTile = true
                let sx = Double(tx) * ts - originX
                let imgTopScreen = Double(ty) * ts - originY
                ctx.saveGState()
                ctx.translateBy(x: sx, y: Double(h) - imgTopScreen)   // tile top-left in y-up ctx
                ctx.scaleBy(x: 1, y: -1)                              // draw image upright
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: ts, height: ts))
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()

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
        // Heading-up: map is rotated, so the rider always points up (no
        // rotation). North-up: rotate the chevron to the heading (clockwise =
        // negative in a y-up context).
        if !headingUp { ctx.rotate(by: -headingDegrees * .pi / 180.0) }
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

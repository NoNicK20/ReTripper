//
//  GoogleMapFrameSource.swift
//  ReTripper
//
//  The real dash map: renders 526×300 frames from Google Map Tiles centred
//  on the rider, with a heading chevron and — when the rider is navigating —
//  the active route line and a next-turn banner, then feeds them to the
//  H.264 streamer. Tiles are fetched and cached asynchronously; the rider's
//  position and heading are smoothed between GPS fixes so the map glides
//  instead of jumping.
//
//  North-up or heading-up follows the rider's setting (DashMapDefaults).
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
    /// MUST stay 4: the Tripper dash decoder fragments the picture above
    /// ~12 fps (and the extra RTP packets get lost, collapsing the stream).
    /// Matches the stock RE app / TripperDash++ stream shape. The frame is
    /// still re-rendered from the smoothed position every tick, so panning
    /// stays fluid between the ~1 Hz GPS fixes even at 4 fps.
    let targetFps = 4
    var zoom = 16

    /// How far the smoothed position/heading moves toward the latest GPS fix
    /// each frame (0–1), tuned for 4 fps: ~4 frames between GPS fixes, so a
    /// higher factor keeps up without jumping.
    private let smoothing = 0.45

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

    /// Latest GPS fix / heading (the target the render values ease toward).
    private var targetCoordinate: CLLocationCoordinate2D?
    private var targetHeading: Double = 0
    /// Smoothed values actually drawn, advanced toward the targets each tick.
    private var renderCoordinate: CLLocationCoordinate2D?
    private var renderHeading: Double = 0

    private var tileMirror: [GoogleTileFetcher.TileKey: CGImage] = [:]
    private var refreshing = false
    /// Plain-language reason the map tiles aren't loading (from the fetcher),
    /// shown on the frame so the cause is visible on the dash itself.
    private var tileDiagnostic: String?

    private let apexRed = CGColor(red: 0.86, green: 0.08, blue: 0.09, alpha: 1)
    private let routeBlue = CGColor(red: 0.13, green: 0.50, blue: 0.96, alpha: 1)

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
        targetCoordinate = loc.coordinate
        if loc.course >= 0 && loc.speed > 2 { targetHeading = loc.course }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        if h >= 0 { targetHeading = h }
    }

    // MARK: - Render loop

    private func tick() {
        advanceSmoothing()
        renderFrame()
        kickTileRefresh()
    }

    /// Ease the drawn position/heading toward the latest fix so motion glides.
    private func advanceSmoothing() {
        guard let target = targetCoordinate else { return }
        if let r = renderCoordinate {
            renderCoordinate = CLLocationCoordinate2D(
                latitude: r.latitude + (target.latitude - r.latitude) * smoothing,
                longitude: r.longitude + (target.longitude - r.longitude) * smoothing)
        } else {
            renderCoordinate = target   // snap on the first fix
            renderHeading = targetHeading
            return
        }
        var delta = (targetHeading - renderHeading).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        renderHeading = (renderHeading + delta * smoothing).truncatingRemainder(dividingBy: 360)
        if renderHeading < 0 { renderHeading += 360 }
    }

    private func kickTileRefresh() {
        guard let coord = targetCoordinate, !refreshing else { return }
        let keys = tileKeys(center: coord)
        refreshing = true
        let fetcher = self.fetcher
        Task { [weak self] in
            await fetcher.prefetch(keys)
            let images = await fetcher.images(keys)
            let diagnostic = await fetcher.lastSessionError
            await MainActor.run { [weak self] in
                self?.tileMirror = images
                self?.tileDiagnostic = diagnostic
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

        // Flip the Y axis ONCE so the whole drawing path is y-DOWN with the
        // origin at the top-left — the orientation the Tripper dash reads the
        // frame in. TripperDash++'s proven renderer does exactly this; without
        // it the map comes out upside-down / mirrored on the dash.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Dark background.
        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        guard let coord = renderCoordinate else {
            drawCentreText("Waiting for GPS…", in: ctx, size: CGSize(width: w, height: h))
            emit(buffer)
            return
        }

        let headingUp = DashMapDefaults.headingUp

        // y-down: +y is DOWN the frame. World-pixel y also increases south, so
        // a tile/route point's screen y is just (worldY - originY) — north ends
        // up at the top. originY is the world-y at the top (north) edge.
        let c = WebMercator.worldPixel(coord, zoom: zoom)
        let originX = c.x - Double(w) / 2         // world-x at the left edge
        let originY = c.y - Double(h) / 2         // world-y at the top (north) edge
        let ts = WebMercator.tileSize
        let r = tileRange(center: c)

        ctx.saveGState()
        if headingUp {
            ctx.translateBy(x: Double(w) / 2, y: Double(h) / 2)
            ctx.rotate(by: -renderHeading * .pi / 180.0)   // y-down heading-up
            ctx.translateBy(x: -Double(w) / 2, y: -Double(h) / 2)
        }
        var anyTile = false
        for ty in r.minTY...r.maxTY {
            for tx in r.minTX...r.maxTX {
                guard let wk = WebMercator.wrap(x: tx, y: ty, zoom: zoom),
                      let img = tileMirror[.init(z: zoom, x: wk.x, y: wk.y)] else { continue }
                anyTile = true
                let sx = Double(tx) * ts - originX
                let sy = Double(ty) * ts - originY            // y-down tile top
                drawImageUpright(img, in: CGRect(x: sx, y: sy, width: ts, height: ts), ctx: ctx)
            }
        }
        // Route line sits on the map, so it's drawn inside the same transform.
        drawRouteLine(in: ctx, originX: originX, originY: originY)
        ctx.restoreGState()

        if !anyTile {
            drawCentreText(tileDiagnostic ?? "Loading map…",
                           in: ctx, size: CGSize(width: w, height: h))
        } else {
            drawRiderMarker(in: ctx, center: CGPoint(x: Double(w) / 2, y: Double(h) / 2),
                            headingUp: headingUp)
        }
        // Turn banner (screen-space, always upright) on top of everything.
        drawManeuverBanner(in: ctx, width: w, height: h)
        emit(buffer)
    }

    /// Draw a CGImage upright in the y-down context (a plain `ctx.draw` would
    /// render it upside down there).
    private func drawImageUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Draws the active navigation route (if any) in the current map transform.
    private func drawRouteLine(in ctx: CGContext, originX: Double, originY: Double) {
        let coords = DashRouteStore.shared.snapshot.coords
        guard coords.count >= 2 else { return }
        let points = coords.map { coord -> CGPoint in
            let wp = WebMercator.worldPixel(coord, zoom: zoom)
            return CGPoint(x: wp.x - originX, y: wp.y - originY)   // y-down
        }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        // White casing for contrast, then the blue route on top.
        ctx.beginPath(); ctx.addLines(between: points)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(8); ctx.strokePath()
        ctx.beginPath(); ctx.addLines(between: points)
        ctx.setStrokeColor(routeBlue)
        ctx.setLineWidth(5); ctx.strokePath()
    }

    /// Next-turn banner (arrow + distance) along the top, drawn upright.
    private func drawManeuverBanner(in ctx: CGContext, width w: Int, height h: Int) {
        let snap = DashRouteStore.shared.snapshot
        guard snap.hasRoute, !snap.maneuver.isEmpty else { return }
        let text = "\(Self.arrow(for: snap.maneuver))  \(Self.distanceText(snap.distanceToManeuver))"
        let bannerH: CGFloat = 34
        let rect = CGRect(x: 8, y: 8, width: CGFloat(w) - 16, height: bannerH)   // top in y-down
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
        ctx.fillPath()
        drawText(text, at: CGPoint(x: rect.minX + 14, y: rect.midY + 6), fontSize: 19,
                 color: CGColor(red: 1, green: 1, blue: 1, alpha: 1), in: ctx)
    }

    private static func arrow(for maneuver: String) -> String {
        let m = maneuver.uppercased()
        if m.contains("UTURN") { return "⟲" }
        if m.contains("LEFT") { return "←" }
        if m.contains("RIGHT") { return "→" }
        return "↑"
    }

    private static func distanceText(_ metres: Double) -> String {
        metres >= 1000 ? String(format: "%.1f km", metres / 1000) : String(format: "%.0f m", metres)
    }

    private func drawRiderMarker(in ctx: CGContext, center: CGPoint, headingUp: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        // y-down. Heading-up: the map is already rotated, so the chevron stays
        // pointing up. North-up: rotate the chevron to the heading (CW is
        // positive in a y-down context).
        if !headingUp { ctx.rotate(by: renderHeading * .pi / 180.0) }
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: -16))             // apex points up (−y)
        ctx.addLine(to: CGPoint(x: -11, y: 12))
        ctx.addLine(to: CGPoint(x: 0, y: 5))
        ctx.addLine(to: CGPoint(x: 11, y: 12))
        ctx.closePath()
        ctx.setFillColor(apexRed)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawCentreText(_ string: String, in ctx: CGContext, size: CGSize) {
        let maxWidth = size.width - 24
        // Shrink the font until the line fits the frame width (down to 10pt).
        var fontSize: CGFloat = 18
        var line = makeLine(string, fontSize: fontSize)
        while CTLineGetImageBounds(line, ctx).width > maxWidth && fontSize > 10 {
            fontSize -= 1
            line = makeLine(string, fontSize: fontSize)
        }
        let bounds = CTLineGetImageBounds(line, ctx)
        drawText(string, at: CGPoint(x: max(12, (size.width - bounds.width) / 2), y: size.height / 2 + 6),
                 fontSize: fontSize,
                 color: CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1), in: ctx)
    }

    /// Draw one line of text upright in the y-down context (glyphs would be
    /// upside down otherwise). `point` is the baseline origin in y-down space.
    private func drawText(_ string: String, at point: CGPoint, fontSize: CGFloat,
                          color: CGColor, in ctx: CGContext) {
        let line = makeLine(string, fontSize: fontSize)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: point.x, y: point.y)
        ctx.scaleBy(x: 1, y: -1)          // flip glyphs upright for the y-down frame
        ctx.textPosition = .zero
        ctx.setFillColor(color)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func makeLine(_ string: String, fontSize: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
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

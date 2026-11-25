//
//  GoogleTileFetcher.swift
//  ReTripper
//
//  Fetches 2D road-map raster tiles from the Google Map Tiles API for the
//  dash renderer. Creates and reuses a session token, caches decoded tiles
//  in memory, and reuses the app's existing Google Maps API key (GMSApiKey).
//
//  Cost control: tiles are cached and only the tiles around the rider are
//  fetched, at a modest zoom. Requires the Map Tiles API enabled on the key
//  and billing enabled on the Google account (rider-side). With no key, all
//  fetches no-op and the renderer shows a "map not configured" frame — it
//  never falls back to another map provider.
//

import CoreGraphics
import Foundation
import ImageIO
import os.log

actor GoogleTileFetcher {

    struct TileKey: Hashable { let z: Int; let x: Int; let y: Int }

    private let apiKey: String?
    private let mapType: String
    private var sessionToken: String?
    private var sessionExpiry: Date?
    private var cache: [TileKey: CGImage] = [:]
    private var inFlight: Set<TileKey> = []
    private let maxCached = 64
    private let session = URLSession(configuration: .ephemeral)
    private let log = Logger(subsystem: "com.nonick20.retripper", category: "Tiles")

    init(apiKey: String? = AppSecretsConfiguration.googleMapsAPIKey, mapType: String = "roadmap") {
        self.apiKey = apiKey
        self.mapType = mapType
    }

    var isConfigured: Bool { apiKey != nil }

    /// A decoded tile if it's already cached, else nil (never blocks).
    func cachedTile(_ key: TileKey) -> CGImage? { cache[key] }

    /// Snapshot of whichever of `keys` are currently cached.
    func images(_ keys: [TileKey]) -> [TileKey: CGImage] {
        var out: [TileKey: CGImage] = [:]
        for k in keys where cache[k] != nil { out[k] = cache[k] }
        return out
    }

    /// Ensure the given tiles are fetched into the cache. Returns once the
    /// requested fetches have completed (missing/failed tiles stay absent).
    func prefetch(_ keys: [TileKey]) async {
        guard apiKey != nil else { return }
        await withTaskGroup(of: Void.self) { group in
            for key in keys where cache[key] == nil && !inFlight.contains(key) {
                inFlight.insert(key)
                group.addTask { await self.fetch(key) }
            }
        }
    }

    private func fetch(_ key: TileKey) async {
        defer { inFlight.remove(key) }
        guard let token = await ensureSession(), let apiKey else { return }
        guard let url = URL(string: "https://tile.googleapis.com/v1/2dtiles/\(key.z)/\(key.x)/\(key.y)?session=\(token)&key=\(apiKey)") else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = decode(data) else { return }
            store(key, image)
        } catch {
            log.debug("tile fetch failed \(key.z)/\(key.x)/\(key.y): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func store(_ key: TileKey, _ image: CGImage) {
        cache[key] = image
        if cache.count > maxCached {
            // Drop down to ~¾ capacity (simple bound). Copy the keys first so
            // we don't mutate the dictionary while iterating it.
            let drop = Array(cache.keys).prefix(cache.count - maxCached * 3 / 4)
            for k in drop { cache[k] = nil }
        }
    }

    private func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Session token

    private func ensureSession() async -> String? {
        if let token = sessionToken, let expiry = sessionExpiry, expiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let apiKey,
              let url = URL(string: "https://tile.googleapis.com/v1/createSession?key=\(apiKey)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["mapType": mapType, "language": "en-US", "region": "US"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["session"] as? String else {
                log.error("createSession failed")
                return nil
            }
            sessionToken = token
            if let expiry = json["expiry"] as? String, let seconds = TimeInterval(expiry) {
                sessionExpiry = Date(timeIntervalSince1970: seconds)
            } else {
                sessionExpiry = Date().addingTimeInterval(3600)
            }
            return token
        } catch {
            log.error("createSession error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

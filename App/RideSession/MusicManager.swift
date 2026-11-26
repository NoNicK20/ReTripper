//
//  MusicManager.swift
//  ReTripper
//
//  Modular music control.
//  - Apple Music: MediaPlayer's system music player (public API). It controls and
//    reports only what the Music app is playing — not other apps.
//  - Spotify: Spotify's official App Remote SDK (see SpotifyMusicProvider.swift).
//    Shows the current track and does play/pause/next/previous once the rider
//    links their Spotify account.
//

import Foundation
import MediaPlayer
import UIKit
import Combine

enum MusicProviderKind: String, CaseIterable, Identifiable {
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    var id: String { rawValue }
}

enum MusicAvailability: Equatable {
    case available
    case needsAuthorization
    case denied
    case notConfigured(String)

    var isAvailable: Bool { self == .available }
}

enum PlaybackState: Equatable { case playing, paused, stopped, unknown }

struct NowPlaying: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var artwork: UIImage?

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
    }
}

@MainActor
protocol MusicProvider: AnyObject {
    var kind: MusicProviderKind { get }
    var availability: MusicAvailability { get }
    var nowPlaying: NowPlaying? { get }
    var playbackState: PlaybackState { get }
    var onChange: (() -> Void)? { get set }
    func requestAuthorization() async
    func togglePlayPause()
    func next()
    func previous()
}

// MARK: - Apple Music (MediaPlayer)

@MainActor
final class AppleMusicProvider: MusicProvider {
    let kind: MusicProviderKind = .appleMusic
    var onChange: (() -> Void)?
    private(set) var availability: MusicAvailability = .needsAuthorization
    private(set) var nowPlaying: NowPlaying?
    private(set) var playbackState: PlaybackState = .unknown

    private var player: MPMusicPlayerController?
    private var observers: [NSObjectProtocol] = []

    init() {
        updateAvailability(MPMediaLibrary.authorizationStatus())
    }

    func requestAuthorization() async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        updateAvailability(status)
    }

    private func updateAvailability(_ status: MPMediaLibraryAuthorizationStatus) {
        switch status {
        case .authorized:
            availability = .available
            attachPlayer()
        case .notDetermined:
            availability = .needsAuthorization
        case .denied, .restricted:
            availability = .denied
        @unknown default:
            availability = .denied
        }
        onChange?()
    }

    private func attachPlayer() {
        guard player == nil else { return }
        let p = MPMusicPlayerController.systemMusicPlayer
        player = p
        p.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: p, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshState() }
            })
        }
        refreshState()
    }

    private func refreshState() {
        guard let p = player else { return }
        if let item = p.nowPlayingItem {
            nowPlaying = NowPlaying(title: item.title ?? "Unknown title",
                                    artist: item.artist,
                                    album: item.albumTitle,
                                    artwork: item.artwork?.image(at: CGSize(width: 120, height: 120)))
        } else {
            nowPlaying = nil
        }
        switch p.playbackState {
        case .playing: playbackState = .playing
        case .paused, .interrupted: playbackState = .paused
        case .stopped: playbackState = .stopped
        default: playbackState = .unknown
        }
        onChange?()
    }

    func togglePlayPause() {
        guard availability.isAvailable, let p = player else { return }
        if p.playbackState == .playing { p.pause() } else { p.play() }
    }

    func next() {
        guard availability.isAvailable else { return }
        player?.skipToNextItem()
    }

    func previous() {
        guard availability.isAvailable, let p = player else { return }
        // Restart the track if it has been playing for a while, like the Music app.
        if p.currentPlaybackTime > 5 { p.skipToBeginning() } else { p.skipToPreviousItem() }
    }
}

// Spotify is provided by SpotifyMusicProvider (see SpotifyMusicProvider.swift),
// which uses Spotify's official App Remote SDK.

// MARK: - Manager

@MainActor
final class MusicManager: ObservableObject {
    static let shared = MusicManager()

    @Published var selectedKind: MusicProviderKind = .appleMusic
    @Published private(set) var availability: MusicAvailability = .needsAuthorization
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var playbackState: PlaybackState = .unknown

    private let providers: [MusicProviderKind: MusicProvider]

    init(providers: [MusicProvider]? = nil) {
        let list = providers ?? [AppleMusicProvider(), SpotifyMusicProvider()]
        var map: [MusicProviderKind: MusicProvider] = [:]
        for p in list { map[p.kind] = p }
        self.providers = map
        for p in list { p.onChange = { [weak self] in self?.sync() } }
        sync()
    }

    var current: MusicProvider? { providers[selectedKind] }

    func select(_ kind: MusicProviderKind) {
        selectedKind = kind
        sync()
    }

    func availability(of kind: MusicProviderKind) -> MusicAvailability {
        providers[kind]?.availability ?? .notConfigured("Provider missing")
    }

    func requestAuthorization() async {
        await current?.requestAuthorization()
        sync()
    }

    func togglePlayPause() { current?.togglePlayPause() }
    func next() { current?.next() }
    func previous() { current?.previous() }

    // MARK: - Spotify link lifecycle (forwarded from the app entry point)

    private var spotify: SpotifyMusicProvider? { providers[.spotify] as? SpotifyMusicProvider }

    /// The Spotify authorization redirect, registered on the Spotify dashboard
    /// and sharing the app's existing `retripper` URL scheme.
    static func isSpotifyCallback(_ url: URL) -> Bool {
        url.scheme == "retripper" && url.host == "spotify-callback"
    }

    /// True when the URL was the Spotify authorization redirect and was handled.
    func handleSpotifyCallback(_ url: URL) -> Bool {
        guard MusicManager.isSpotifyCallback(url) else { return false }
        spotify?.handleAuthCallback(url)
        return true
    }

    func appBecameActive() { spotify?.onBecomeActive() }
    func appResignedActive() { spotify?.onResignActive() }

    private func sync() {
        guard let p = current else { return }
        availability = p.availability
        nowPlaying = p.nowPlaying
        playbackState = p.playbackState
    }
}

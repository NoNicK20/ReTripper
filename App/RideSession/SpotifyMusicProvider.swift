//
//  SpotifyMusicProvider.swift
//  ReTripper
//
//  Spotify integration via Spotify's official iOS SDK (App Remote). It connects
//  to the Spotify app installed on the phone and reports the current track plus
//  play / pause / next / previous — the same surface the Apple Music provider
//  exposes, so the Ride music card and the bike's control stick drive it too.
//
//  App Remote talks to the Spotify app over a local link. It needs a physical
//  device with the Spotify app installed; it does nothing on the Simulator. The
//  rider authorises once (Spotify opens, then returns to ReTripper via the
//  retripper://spotify-callback redirect) and the access token is remembered.
//
//  Showing the track works on any Spotify account. On-demand skipping is subject
//  to the rider's own Spotify account tier — a free account keeps Spotify's own
//  skip limits. ReTripper only uses the official SDK; it does nothing to bypass
//  Spotify's account rules.
//

import Foundation
import UIKit

#if canImport(SpotifyiOS)
import SpotifyiOS

@MainActor
final class SpotifyMusicProvider: NSObject, MusicProvider {
    let kind: MusicProviderKind = .spotify
    var onChange: (() -> Void)?
    private(set) var nowPlaying: NowPlaying?
    private(set) var playbackState: PlaybackState = .unknown
    private(set) var availability: MusicAvailability

    private let clientID: String?
    private let tokenKey = "retripper_spotify_access_token"

    private var storedToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    private lazy var appRemote: SPTAppRemote? = {
        guard let clientID,
              let redirectURL = URL(string: "retripper://spotify-callback") else { return nil }
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.connectionParameters.accessToken = storedToken
        remote.delegate = self
        return remote
    }()

    init(clientID: String? = AppSecretsConfiguration.spotifyClientID) {
        self.clientID = clientID
        self.availability = clientID == nil
            ? .notConfigured("Add a Spotify client ID to this build to connect Spotify.")
            : .needsAuthorization
        super.init()
    }

    // MARK: - MusicProvider

    /// Called when the rider taps "Allow Spotify access". Reconnects silently if
    /// a token is already stored, otherwise launches Spotify to authorise.
    func requestAuthorization() async {
        guard let appRemote else {
            availability = .notConfigured("Add a Spotify client ID to this build to connect Spotify.")
            onChange?()
            return
        }
        if appRemote.isConnected { return }

        if let token = storedToken, !token.isEmpty {
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
            return
        }

        // Empty play URI = don't force playback; just authorise and connect.
        appRemote.authorizeAndPlayURI("") { [weak self] success in
            guard !success else { return }
            Task { @MainActor in
                self?.availability = .notConfigured("Spotify app not found. Install Spotify, then connect.")
                self?.onChange?()
            }
        }
    }

    func togglePlayPause() {
        guard let player = appRemote?.playerAPI else { return }
        if playbackState == .playing {
            player.pause { _, _ in }
        } else {
            player.resume { _, _ in }
        }
    }

    func next() { appRemote?.playerAPI?.skip(toNext: { _, _ in }) }

    func previous() { appRemote?.playerAPI?.skip(toPrevious: { _, _ in }) }

    // MARK: - App lifecycle hooks (called from the app entry)

    /// Completes authorisation when Spotify re-opens ReTripper via the redirect.
    func handleAuthCallback(_ url: URL) {
        guard let appRemote else { return }
        let parameters = appRemote.authorizationParameters(from: url)
        if let token = parameters?[SPTAppRemoteAccessTokenKey] {
            storedToken = token
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else if let errorDescription = parameters?[SPTAppRemoteErrorDescriptionKey] {
            availability = .notConfigured("Spotify authorization failed: \(errorDescription)")
            onChange?()
        }
    }

    /// Reconnect when ReTripper returns to the foreground, but only if the rider
    /// has already linked Spotify (a stored token). Never launches Spotify itself.
    func onBecomeActive() {
        guard let appRemote, let token = storedToken, !token.isEmpty, !appRemote.isConnected else { return }
        appRemote.connectionParameters.accessToken = token
        appRemote.connect()
    }

    func onResignActive() {
        appRemote?.disconnect()
    }

    // MARK: - Connection

    private func onConnected() {
        guard let appRemote else { return }
        availability = .available
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe { _, _ in }
        appRemote.playerAPI?.getPlayerState { [weak self] result, _ in
            guard let state = result as? SPTAppRemotePlayerState else { return }
            Task { @MainActor in self?.apply(state) }
        }
        onChange?()
    }

    private func apply(_ state: SPTAppRemotePlayerState) {
        let track = state.track
        nowPlaying = NowPlaying(title: track.name,
                                artist: track.artist.name,
                                album: nil,
                                artwork: nowPlaying?.artwork)
        playbackState = state.isPaused ? .paused : .playing
        availability = .available
        onChange?()
        fetchArtwork(for: track)
    }

    private func fetchArtwork(for track: SPTAppRemoteTrack) {
        appRemote?.imageAPI?.fetchImage(forItem: track, with: CGSize(width: 120, height: 120)) { [weak self] image, _ in
            guard let artwork = image as? UIImage else { return }
            Task { @MainActor in
                self?.nowPlaying?.artwork = artwork
                self?.onChange?()
            }
        }
    }
}

// MARK: - SDK delegates (called by the Spotify SDK; hop to the main actor)

extension SpotifyMusicProvider: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.onConnected() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.availability = .needsAuthorization
            self.onChange?()
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.playbackState = .unknown
            self.onChange?()
        }
    }
}

extension SpotifyMusicProvider: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor in self.apply(playerState) }
    }
}

#else

/// Fallback when the Spotify SDK is not linked into the build: keeps the app
/// compiling and reports Spotify as unavailable instead of pretending.
@MainActor
final class SpotifyMusicProvider: MusicProvider {
    let kind: MusicProviderKind = .spotify
    var onChange: (() -> Void)?
    let nowPlaying: NowPlaying? = nil
    let playbackState: PlaybackState = .unknown
    var availability: MusicAvailability { .notConfigured("The Spotify SDK is not linked in this build.") }

    init(clientID: String? = nil) {}

    func requestAuthorization() async {}
    func togglePlayPause() {}
    func next() {}
    func previous() {}
    func handleAuthCallback(_ url: URL) {}
    func onBecomeActive() {}
    func onResignActive() {}
}

#endif

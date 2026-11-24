//
//  NavigationAudioManager.swift
//  ReTripper
//
//  Spoken navigation guidance via AVSpeechSynthesizer using public AVAudioSession APIs.
//  - Ducks music while speaking, then restores it.
//  - Audio follows the iOS output route (e.g. a paired Bluetooth helmet headset);
//    the rider can choose the route with the system route picker. No private APIs.
//  - Pauses for phone calls and other interruptions and repeats the current
//    instruction afterwards.
//  - Stays silent when the Google Navigation SDK is producing its own voice guidance.
//

import Foundation
import AVFoundation
import Combine

enum GuidanceMode: String, CaseIterable, Identifiable, Codable {
    case full = "Full guidance"
    case importantOnly = "Important only"
    case muted = "Muted"
    var id: String { rawValue }
}

/// Decides which instructions to speak and when. Pure logic so it can be tested.
struct GuidanceAnnouncementPlanner {
    private(set) var spokenKeys = Set<String>()

    mutating func reset() { spokenKeys.removeAll() }

    static func prepareDistance(speedMps: Double) -> Double { max(350, speedMps * 22) }
    static func imminentDistance(speedMps: Double) -> Double { max(60, speedMps * 7) }

    mutating func announcement(for progress: RouteProgress, mode: GuidanceMode, speedMps: Double) -> String? {
        guard mode != .muted else { return nil }
        let d = progress.distanceToNextManeuverMeters
        let isMinor = progress.nextManeuver == .straight || progress.nextManeuver == .depart
        if mode == .importantOnly && isMinor { return nil }

        let imminentKey = "\(progress.stepIndex)-now"
        let prepareKey = "\(progress.stepIndex)-prepare"

        if d <= Self.imminentDistance(speedMps: speedMps) {
            guard !spokenKeys.contains(imminentKey) else { return nil }
            spokenKeys.insert(imminentKey)
            spokenKeys.insert(prepareKey)
            return progress.nextInstruction
        }
        if mode == .full, d <= Self.prepareDistance(speedMps: speedMps), d > Self.imminentDistance(speedMps: speedMps) * 1.5 {
            guard !spokenKeys.contains(prepareKey) else { return nil }
            spokenKeys.insert(prepareKey)
            return "In \(Self.spokenDistance(d)), \(Self.lowercasedFirst(progress.nextInstruction))"
        }
        return nil
    }

    static func spokenDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            let km = (meters / 100).rounded() / 10
            return km == km.rounded() ? "\(Int(km)) kilometers" : String(format: "%.1f kilometers", km)
        }
        let rounded = max(50, Int((meters / 50).rounded()) * 50)
        return "\(rounded) meters"
    }

    static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}

@MainActor
final class NavigationAudioManager: NSObject, ObservableObject {
    static let shared = NavigationAudioManager()

    @Published var mode: GuidanceMode = .full {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: modeKey); if mode == .muted { stopSpeaking() } }
    }
    /// Voice volume relative to the system volume (0.1 – 1.0).
    @Published var voiceVolume: Float = 1.0 {
        didSet { UserDefaults.standard.set(voiceVolume, forKey: volumeKey) }
    }
    @Published private(set) var isSpeaking = false
    @Published private(set) var isInterrupted = false
    @Published private(set) var lastInstruction: String?
    @Published private(set) var currentOutputName: String = "iPhone"

    /// Set when another engine (Google Navigation SDK) speaks its own guidance.
    var externalEngineSpeaks = false

    private let synthesizer = AVSpeechSynthesizer()
    private var planner = GuidanceAnnouncementPlanner()
    private var pendingAfterInterruption: String?
    private var callActive = false
    private let modeKey = "retripper_guidance_mode"
    private let volumeKey = "retripper_guidance_volume"

    override init() {
        super.init()
        synthesizer.delegate = self
        if let raw = UserDefaults.standard.string(forKey: modeKey), let saved = GuidanceMode(rawValue: raw) {
            mode = saved
        }
        let savedVolume = UserDefaults.standard.float(forKey: volumeKey)
        if savedVolume > 0 { voiceVolume = min(1, max(0.1, savedVolume)) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        refreshOutputName()
    }

    // MARK: Inputs

    func routeChanged() {
        planner.reset()
    }

    func handle(progress: RouteProgress, speedMps: Double) {
        guard !externalEngineSpeaks else { return }
        if let text = planner.announcement(for: progress, mode: mode, speedMps: speedMps) {
            speak(text)
        }
    }

    /// Important events (reroute, arrival) are spoken in full and important-only modes.
    func announceEvent(_ text: String) {
        guard !externalEngineSpeaks, mode != .muted else { return }
        speak(text)
    }

    func repeatLastInstruction() {
        guard let text = lastInstruction else { return }
        speak(text, force: true)
    }

    func setCallActive(_ active: Bool) {
        let wasActive = callActive
        callActive = active
        if active {
            if synthesizer.isSpeaking { pendingAfterInterruption = lastInstruction }
            stopSpeaking()
        } else if wasActive, let pending = pendingAfterInterruption ?? lastInstruction, mode != .muted, !externalEngineSpeaks {
            pendingAfterInterruption = nil
            speak(pending)
        }
    }

    // MARK: Speech

    private func speak(_ text: String, force: Bool = false) {
        lastInstruction = text
        guard force || mode != .muted else { return }
        guard !callActive, !isInterrupted else {
            pendingAfterInterruption = text
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // If the session cannot be configured we still try to speak through the current route.
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = voiceVolume
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        deactivateSession()
    }

    private func deactivateSession() {
        // Restores (un-ducks) the rider's music.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func refreshOutputName() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        currentOutputName = outputs.first?.portName ?? "iPhone"
    }

    // MARK: Notifications

    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor in
            switch type {
            case .began:
                self.isInterrupted = true
                if self.synthesizer.isSpeaking { self.pendingAfterInterruption = self.lastInstruction }
                self.isSpeaking = false
            case .ended:
                self.isInterrupted = false
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume), let pending = self.pendingAfterInterruption, !self.callActive {
                    self.pendingAfterInterruption = nil
                    self.speak(pending)
                }
            @unknown default:
                break
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ note: Notification) {
        Task { @MainActor in self.refreshOutputName() }
    }
}

extension NavigationAudioManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}

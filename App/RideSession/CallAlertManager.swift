//
//  CallAlertManager.swift
//  ReTripper
//
//  Observes phone call state with the public CXCallObserver API.
//  iOS does not give third-party apps the caller's name or number, call audio,
//  or the ability to answer/decline cellular calls, so ReTripper shows only
//  "incoming call", "call active" and "call ended" states.
//

import Foundation
import CallKit
import Combine

enum CallPhase: Equatable {
    case none
    case incoming
    case outgoing
    case active
    case onHold
    case ended
}

/// Snapshot of one call, decoupled from CXCall for testing.
struct CallSnapshot: Equatable {
    var isOutgoing: Bool
    var hasConnected: Bool
    var hasEnded: Bool
    var isOnHold: Bool
}

enum CallPhaseResolver {
    static func phase(for calls: [CallSnapshot]) -> CallPhase {
        let live = calls.filter { !$0.hasEnded }
        if live.isEmpty { return calls.isEmpty ? .none : .ended }
        if live.contains(where: { !$0.isOutgoing && !$0.hasConnected }) { return .incoming }
        if live.contains(where: { $0.hasConnected && !$0.isOnHold }) { return .active }
        if live.contains(where: { $0.isOnHold }) { return .onHold }
        return .outgoing
    }
}

@MainActor
final class CallAlertManager: NSObject, ObservableObject {
    static let shared = CallAlertManager()

    @Published private(set) var phase: CallPhase = .none
    let phaseChanges = PassthroughSubject<CallPhase, Never>()

    private let observer = CXCallObserver()
    private var endedResetTask: Task<Void, Never>?

    var isCallInProgress: Bool {
        phase == .incoming || phase == .outgoing || phase == .active || phase == .onHold
    }

    override init() {
        super.init()
        observer.setDelegate(self, queue: nil)
        refresh()
    }

    func refresh() {
        let snapshots = observer.calls.map {
            CallSnapshot(isOutgoing: $0.isOutgoing, hasConnected: $0.hasConnected,
                         hasEnded: $0.hasEnded, isOnHold: $0.isOnHold)
        }
        apply(CallPhaseResolver.phase(for: snapshots))
    }

    private func apply(_ newPhase: CallPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        phaseChanges.send(newPhase)
        endedResetTask?.cancel()
        if newPhase == .ended {
            endedResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.phase = .none
            }
        }
    }
}

extension CallAlertManager: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in self.refresh() }
    }
}

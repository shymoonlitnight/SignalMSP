//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// SignalMSP fork only (mute-triggers branch). Not intended for upstream.

import Foundation
import SignalRingRTC
import SignalServiceKit

/// Something outside the app that can toggle call mute, such as a media
/// remote's track-skip buttons. Each source has an on/off switch in the iOS
/// Settings app (Signal/Settings.bundle), off by default.
@MainActor
protocol MuteTriggerSource: AnyObject {
    /// Name used in logs.
    var name: String { get }
    /// Starts listening; call `onTrigger` each time mute should toggle.
    func start(onTrigger: @escaping @MainActor () -> Void)
    func stop()
}

/// Starts the enabled trigger sources once a call is connected (not while it
/// rings or sits in a lobby) and stops them when it ends. Every source toggles mute through `CallMuteController.shared`,
/// whose debounce keeps two sources firing for the same press from
/// cancelling each other out.
@MainActor
final class MuteTriggerCoordinator: CallServiceStateObserver, IndividualCallObserver, GroupCallObserver {
    struct SourceEntry {
        /// UserDefaults key written by the Settings app switch.
        let settingKey: String
        let make: @MainActor () -> MuteTriggerSource
    }

    static let allSources: [SourceEntry] = [
        SourceEntry(settingKey: TrackSkipMuteTrigger.settingKey, make: { TrackSkipMuteTrigger() }),
        SourceEntry(settingKey: HeadTiltMuteTrigger.settingKey, make: { HeadTiltMuteTrigger() }),
    ]

    private let sources: [SourceEntry]
    private let isEnabled: (String) -> Bool
    private let toggleMute: @MainActor () async throws -> Bool

    private var running: [MuteTriggerSource] = []
    private var call: SignalCall?

    init(
        sources: [SourceEntry] = MuteTriggerCoordinator.allSources,
        isEnabled: @escaping (String) -> Bool = { UserDefaults.standard.bool(forKey: $0) },
        toggleMute: @escaping @MainActor () async throws -> Bool = { try await CallMuteController.shared.toggle() },
    ) {
        self.sources = sources
        self.isEnabled = isEnabled
        self.toggleMute = toggleMute
    }

    var runningSourceNames: [String] { running.map(\.name) }

    // MARK: - CallServiceStateObserver

    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        switch oldValue?.mode {
        case nil:
            break
        case .individual(let call):
            call.removeObserver(self)
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            call.removeObserver(self)
        }
        call = newValue
        switch newValue?.mode {
        case nil:
            break
        case .individual(let call):
            call.addObserverAndSyncState(self)
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            call.addObserver(self, syncStateImmediately: true)
        }
        updateRunning()
    }

    // MARK: - IndividualCallObserver

    func individualCallStateDidChange(_ call: IndividualCall, state: CallState) {
        updateRunning()
    }

    // MARK: - GroupCallObserver

    func groupCallLocalDeviceStateChanged(_ call: GroupCall) {
        updateRunning()
    }

    func groupCallEnded(_ call: GroupCall, reason: CallEndReason) {
        updateRunning()
    }

    // MARK: - When sources run

    private func updateRunning() {
        if Self.shouldRun(for: call) {
            callStarted()
        } else {
            callEnded()
        }
    }

    private static func shouldRun(for call: SignalCall?) -> Bool {
        guard let call, !call.hasTerminated else {
            return false
        }
        switch call.mode {
        case .individual(let individualCall):
            return shouldRun(individualState: individualCall.state)
        case .groupThread(let groupCall as GroupCall), .callLink(let groupCall as GroupCall):
            return shouldRun(joinState: groupCall.joinState)
        }
    }

    /// Runs while connected, including while reconnecting (it's the same call).
    /// No `default:`, so a new upstream state has to be placed here.
    static func shouldRun(individualState: CallState?) -> Bool {
        guard let individualState else {
            return false
        }
        switch individualState {
        case .connected, .reconnecting:
            return true
        case .idle, .dialing, .answering, .remoteRinging,
             .localRinging_Anticipatory, .localRinging_ReadyToAnswer, .accepting,
             .localFailure, .localHangup, .remoteHangup, .remoteHangupNeedPermission,
             .remoteBusy, .answeredElsewhere, .declinedElsewhere, .busyElsewhere:
            return false
        }
    }

    /// Runs once joined; not in the lobby, while joining, or waiting to be let in.
    static func shouldRun(joinState: JoinState?) -> Bool {
        guard let joinState else {
            return false
        }
        switch joinState {
        case .joined:
            return true
        case .notJoined, .joining, .pending:
            return false
        }
    }

    // MARK: -

    /// Starts the enabled sources, unless they're already running. Settings
    /// are read here, so changes apply from the next call.
    func callStarted() {
        guard running.isEmpty else {
            return
        }
        running = sources.filter { isEnabled($0.settingKey) }.map { $0.make() }
        for source in running {
            let name = source.name
            source.start { [weak self] in
                self?.trigger(from: name)
            }
        }
        if !running.isEmpty {
            ForkLog.info("MuteTriggers: started \(runningSourceNames)")
        }
    }

    func callEnded() {
        guard !running.isEmpty else {
            return
        }
        ForkLog.info("MuteTriggers: stopping \(runningSourceNames)")
        running.forEach { $0.stop() }
        running = []
    }

    func trigger(from sourceName: String) {
        Task { @MainActor in
            do {
                let isMuted = try await toggleMute()
                ForkLog.info("MuteTriggers: \(sourceName) toggled mute to \(isMuted)")
            } catch {
                ForkLog.warn("MuteTriggers: \(sourceName) couldn't toggle mute: \(error)")
            }
        }
    }
}

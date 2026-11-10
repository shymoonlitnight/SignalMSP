//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Foundation
import SignalServiceKit
import SignalUI

enum CallMuteError: LocalizedError, Equatable {
    case noActiveCall
    case callEnded
    case callNotAnswered
    case unableToChangeMuteState

    var errorDescription: String? {
        switch self {
        case .noActiveCall:
            return "No active call."
        case .callEnded:
            return "The call has already ended."
        case .callNotAnswered:
            return "The call hasn't been answered yet."
        case .unableToChangeMuteState:
            return "Unable to change microphone mute state right now."
        }
    }
}

/// The parts of a call that `CallMuteController` needs.
@MainActor
protocol CallMuteTarget: AnyObject {
    var isMuted: Bool { get }
    var hasEnded: Bool { get }
    /// Still the app's current call. A change that finishes after the call
    /// was replaced or ended mustn't be reported for it.
    var isCurrent: Bool { get }
    /// An incoming call that's ringing and hasn't been answered. Muting it
    /// would carry over when it's answered from CallKit, so it's refused.
    var isRingingUnanswered: Bool { get }
    /// Starts changing the mute state. The change may finish asynchronously.
    func requestMuted(_ isMuted: Bool)
    /// Tells the system call UI (CallKit) about the new mute state.
    func reportMutedToSystem(_ isMuted: Bool)
}

/// Single entry point for changing microphone mute from outside the call
/// screen's own mute button, such as Shortcuts (App Intents).
///
/// Use `shared`, so every way of toggling goes through one debounce: two
/// toggles close together (say a key press and a Shortcut) would otherwise
/// cancel each other out.
@MainActor
final class CallMuteController {
    /// The controller for the app's current call.
    static let shared: CallMuteController = .live()

    private let currentCall: @MainActor () -> CallMuteTarget?
    private let feedback: @MainActor (_ isMuted: Bool) -> Void
    private let pollIntervalNanoseconds: UInt64
    private let maxPolls: Int
    private let debounceInterval: TimeInterval
    private let now: () -> TimeInterval

    private var lastToggleTime: TimeInterval?
    private var changesInProgress = 0

    init(
        currentCall: @escaping @MainActor () -> CallMuteTarget?,
        feedback: @escaping @MainActor (_ isMuted: Bool) -> Void,
        pollIntervalNanoseconds: UInt64 = 50 * NSEC_PER_MSEC,
        maxPolls: Int = 20,
        debounceInterval: TimeInterval = 0.3,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.currentCall = currentCall
        self.feedback = feedback
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPolls = maxPolls
        self.debounceInterval = debounceInterval
        self.now = now
    }

    private static func live() -> CallMuteController {
        let earcon = CallMuteEarcon()
        return CallMuteController(
            currentCall: {
                guard
                    let callService = AppEnvironment.shared.callService,
                    let call = callService.callServiceState.currentCall
                else {
                    return nil
                }
                return SignalCallMuteTarget(callService: callService, call: call)
            },
            feedback: { isMuted in
                ImpactHapticFeedback.impactOccurred(style: .medium)
                // The haptic can't be felt with the phone in a pocket, and
                // doesn't fire when backgrounded or locked; the tone is heard.
                earcon.play(isMuted: isMuted)
            },
        )
    }

    var hasActiveCall: Bool {
        guard let call = currentCall() else {
            return false
        }
        return !call.hasEnded
    }

    func isMuted() throws -> Bool {
        return try activeCall().isMuted
    }

    /// Flips the mute state and returns the new state. A toggle within
    /// `debounceInterval` of the last one, or while a change is still being
    /// applied, changes nothing and returns the current state: presses that
    /// bounce, or two triggers firing for one gesture, count once.
    @discardableResult
    func toggle() async throws -> Bool {
        let time = now()
        if changesInProgress > 0 || lastToggleTime.map({ time - $0 < debounceInterval }) == true {
            Logger.info("Ignoring a mute toggle close to the previous one")
            return try activeCall().isMuted
        }
        let call = try changeableCall()
        lastToggleTime = time
        return try await setMuted(!call.isMuted, on: call)
    }

    /// Sets the mute state and returns the resulting state. Not debounced:
    /// repeating it changes nothing.
    @discardableResult
    func setMuted(_ isMuted: Bool) async throws -> Bool {
        return try await setMuted(isMuted, on: try changeableCall())
    }

    private func changeableCall() throws -> CallMuteTarget {
        let call = try activeCall()
        if call.isRingingUnanswered {
            throw CallMuteError.callNotAnswered
        }
        return call
    }

    private func activeCall() throws -> CallMuteTarget {
        guard let call = currentCall() else {
            throw CallMuteError.noActiveCall
        }
        if call.hasEnded {
            throw CallMuteError.callEnded
        }
        return call
    }

    private func setMuted(_ isMuted: Bool, on call: CallMuteTarget) async throws -> Bool {
        changesInProgress += 1
        defer { changesInProgress -= 1 }

        call.requestMuted(isMuted)

        let applied = await waitForMuteState(isMuted, call: call)

        // The call may have ended while waiting; CallKit mustn't hear about it.
        guard call.isCurrent, !call.hasEnded else {
            throw CallMuteError.callEnded
        }
        guard applied else {
            throw CallMuteError.unableToChangeMuteState
        }

        call.reportMutedToSystem(isMuted)
        feedback(isMuted)
        return call.isMuted
    }

    private func waitForMuteState(_ targetState: Bool, call: CallMuteTarget) async -> Bool {
        for _ in 0..<maxPolls {
            if call.isMuted == targetState {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return call.isMuted == targetState
    }
}

/// A short tone in the call audio when mute changes: falling for mute,
/// rising for unmute. Played on its own player, not through
/// CallAudioService, so it doesn't stop a ringback or join sound.
@MainActor
final class CallMuteEarcon {
    private var player: AudioPlayer?

    func play(isMuted: Bool) {
        player?.stop()
        let sound: StandardSound = isMuted ? .beginNextTrack : .endLastTrack
        player = Sounds.audioPlayer(forSound: .standard(sound), audioBehavior: .call)
        player?.play()
    }
}

@MainActor
private final class SignalCallMuteTarget: CallMuteTarget {
    private let callService: CallService
    private let call: SignalCall

    init(callService: CallService, call: SignalCall) {
        self.callService = callService
        self.call = call
    }

    var isMuted: Bool { call.isOutgoingAudioMuted }
    var hasEnded: Bool { call.hasTerminated }
    var isCurrent: Bool { callService.callServiceState.currentCall === call }

    var isRingingUnanswered: Bool {
        guard case .individual(let individualCall) = call.mode else {
            return false
        }
        switch individualCall.state {
        case .localRinging_Anticipatory, .localRinging_ReadyToAnswer:
            return true
        default:
            return false
        }
    }

    func requestMuted(_ isMuted: Bool) {
        switch call.mode {
        case .groupThread(let groupCall as GroupCall), .callLink(let groupCall as GroupCall):
            // Keep the lobby's automatic mute from undoing this choice.
            groupCall.didOverrideDefaultMuteState = true
        case .individual:
            break
        }
        if isMuted || AVAudioSession.sharedInstance().recordPermission == .granted {
            // Apply the change directly so it works while locked or
            // backgrounded, without visible call controls.
            callService.updateIsLocalAudioMutedWithMicrophonePermission(call: call, isLocalAudioMuted: isMuted)
        } else {
            // Unmuting needs microphone permission; use the normal flow so the
            // permission prompt behaves as it does from the call screen.
            callService.updateIsLocalAudioMuted(isLocalAudioMuted: isMuted)
        }
    }

    func reportMutedToSystem(_ isMuted: Bool) {
        callService.callUIAdapter.setIsMuted(call: call, isMuted: isMuted)
    }
}

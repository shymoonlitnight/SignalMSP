//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Foundation
import SignalServiceKit

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
@MainActor
final class CallMuteController {
    private let currentCall: @MainActor () -> CallMuteTarget?
    private let feedback: @MainActor (_ isMuted: Bool) -> Void
    private let pollIntervalNanoseconds: UInt64
    private let maxPolls: Int

    init(
        currentCall: @escaping @MainActor () -> CallMuteTarget?,
        feedback: @escaping @MainActor (_ isMuted: Bool) -> Void,
        pollIntervalNanoseconds: UInt64 = 50 * NSEC_PER_MSEC,
        maxPolls: Int = 20,
    ) {
        self.currentCall = currentCall
        self.feedback = feedback
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPolls = maxPolls
    }

    /// A controller for the app's current call.
    static func live() -> CallMuteController {
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
            feedback: { _ in
                ImpactHapticFeedback.impactOccurred(style: .medium)
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

    /// Flips the mute state and returns the new state.
    @discardableResult
    func toggle() async throws -> Bool {
        let call = try changeableCall()
        return try await setMuted(!call.isMuted, on: call)
    }

    /// Sets the mute state and returns the resulting state.
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
        call.requestMuted(isMuted)

        guard await waitForMuteState(isMuted, call: call) else {
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

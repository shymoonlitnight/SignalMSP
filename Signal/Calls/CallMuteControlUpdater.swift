//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalRingRTC
import WidgetKit

/// Keeps the Control Center mute toggle in step with the current call,
/// whatever changed the mute state (call screen, CallKit, shortcuts, keys).
@MainActor
final class CallMuteControlUpdater: CallServiceStateObserver, IndividualCallObserver, GroupCallObserver {
    private var call: SignalCall?
    private var publishedIsMuted: Bool?
    private let store: (Bool) -> Void
    private let reloadControl: () -> Void

    init(
        store: @escaping (Bool) -> Void = { CallMuteControlState.isMuted = $0 },
        reloadControl: @escaping () -> Void = {
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: CallMuteControlState.controlKind)
            }
        },
    ) {
        self.store = store
        self.reloadControl = reloadControl
    }

    /// Mute state the control should show: muted only while a call is active.
    static func isMuted(for call: SignalCall?) -> Bool {
        guard let call, !call.hasTerminated else {
            return false
        }
        return call.isOutgoingAudioMuted
    }

    private func publish() {
        let isMuted = Self.isMuted(for: call)
        guard isMuted != publishedIsMuted else {
            return
        }
        publishedIsMuted = isMuted
        store(isMuted)
        reloadControl()
    }

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
        publish()
    }

    // MARK: - IndividualCallObserver

    func individualCallStateDidChange(_ call: IndividualCall, state: CallState) {
        publish()
    }

    func individualCallLocalAudioMuteDidChange(_ call: IndividualCall, isAudioMuted: Bool) {
        publish()
    }

    // MARK: - GroupCallObserver

    func groupCallLocalDeviceStateChanged(_ call: GroupCall) {
        publish()
    }

    func groupCallEnded(_ call: GroupCall, reason: CallEndReason) {
        publish()
    }
}

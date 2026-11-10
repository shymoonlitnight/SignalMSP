//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// SignalMSP fork only (mute-triggers branch). Not intended for upstream.

import Foundation
import MediaPlayer

/// Where the system's "Now Playing" info lives; a fake in tests.
@MainActor
protocol NowPlayingInfoHolder: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoHolder {}

/// Toggles mute when a media remote sends next/previous track during a call.
///
/// Tested with the BT13 handlebar remote: a slow click (~0.5 s) on − arrives
/// as previous track, even with the phone locked. Play/pause can't be used:
/// during a call iOS turns it into "end call" before the app sees it.
@MainActor
final class TrackSkipMuteTrigger: MuteTriggerSource {
    static let settingKey = "MuteTrigger.trackSkip"
    private static let nowPlayingTitle = "Signal call"

    /// How often to re-claim Now Playing if something else let it go.
    private static let reclaimInterval: TimeInterval = 5

    let name = "trackSkip"
    private let nowPlaying: NowPlayingInfoHolder
    private var targets: [(MPRemoteCommand, Any)] = []
    private var didSetNowPlayingInfo = false
    private var reclaimTimer: Timer?

    init(nowPlaying: NowPlayingInfoHolder = MPNowPlayingInfoCenter.default()) {
        self.nowPlaying = nowPlaying
    }

    func start(onTrigger: @escaping @MainActor () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = true
            let target = command.addTarget { _ in
                Task { @MainActor in onTrigger() }
                return .success
            }
            targets.append((command, target))
        }

        claimNowPlayingIfUnclaimed()
        // A voice message that had Now Playing at call start clears it when
        // its player goes away, which would leave nothing claimed for the
        // rest of the call. Check again from time to time.
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: Self.reclaimInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.claimNowPlayingIfUnclaimed()
            }
        }
    }

    /// Remote commands go to the "Now Playing" app. Claim it only if nothing
    /// else in Signal (e.g. a voice message) has it.
    func claimNowPlayingIfUnclaimed() {
        guard nowPlaying.nowPlayingInfo == nil else {
            return
        }
        nowPlaying.nowPlayingInfo = [MPMediaItemPropertyTitle: Self.nowPlayingTitle]
        didSetNowPlayingInfo = true
    }

    func stop() {
        reclaimTimer?.invalidate()
        reclaimTimer = nil

        // Only remove the targets; other code may have the commands enabled.
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets = []

        if
            didSetNowPlayingInfo,
            nowPlaying.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == Self.nowPlayingTitle
        {
            nowPlaying.nowPlayingInfo = nil
        }
        didSetNowPlayingInfo = false
    }
}

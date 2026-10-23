//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// SignalMSP fork only (mute-triggers branch). Not intended for upstream.

import Foundation
import MediaPlayer

/// Toggles mute when a media remote sends next/previous track during a call.
///
/// Tested with the BT13 handlebar remote: a slow click (~0.5 s) on − arrives
/// as previous track, even with the phone locked. Play/pause can't be used:
/// during a call iOS turns it into "end call" before the app sees it.
@MainActor
final class TrackSkipMuteTrigger: MuteTriggerSource {
    static let settingKey = "MuteTrigger.trackSkip"
    private static let nowPlayingTitle = "Signal call"

    let name = "trackSkip"
    private var targets: [(MPRemoteCommand, Any)] = []
    private var didSetNowPlayingInfo = false

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

        // Remote commands go to the "Now Playing" app. Claim it only if
        // nothing else in Signal (e.g. a voice message) already has.
        let nowPlaying = MPNowPlayingInfoCenter.default()
        if nowPlaying.nowPlayingInfo == nil {
            nowPlaying.nowPlayingInfo = [MPMediaItemPropertyTitle: Self.nowPlayingTitle]
            didSetNowPlayingInfo = true
        }
    }

    func stop() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []

        let nowPlaying = MPNowPlayingInfoCenter.default()
        if
            didSetNowPlayingInfo,
            nowPlaying.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == Self.nowPlayingTitle
        {
            nowPlaying.nowPlayingInfo = nil
        }
        didSetNowPlayingInfo = false
    }
}

//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import MediaPlayer
import XCTest

@testable import Signal

@MainActor
final class TrackSkipMuteTriggerTest: XCTestCase {
    private final class FakeNowPlaying: NowPlayingInfoHolder {
        var nowPlayingInfo: [String: Any]?
    }

    private func title(_ holder: FakeNowPlaying) -> String? {
        return holder.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
    }

    func testReclaimsNowPlayingOnceAVoiceMessageLetsGo() {
        let nowPlaying = FakeNowPlaying()
        nowPlaying.nowPlayingInfo = [MPMediaItemPropertyTitle: "Voice message"]
        let trigger = TrackSkipMuteTrigger(nowPlaying: nowPlaying)

        trigger.claimNowPlayingIfUnclaimed()
        XCTAssertEqual(title(nowPlaying), "Voice message", "doesn't take over")

        // The voice message's player goes away.
        nowPlaying.nowPlayingInfo = nil
        trigger.claimNowPlayingIfUnclaimed()
        XCTAssertEqual(title(nowPlaying), "Signal call")

        trigger.stop()
        XCTAssertNil(nowPlaying.nowPlayingInfo)
    }

    func testStopLeavesSomeoneElsesNowPlayingAlone() {
        let nowPlaying = FakeNowPlaying()
        let trigger = TrackSkipMuteTrigger(nowPlaying: nowPlaying)

        trigger.claimNowPlayingIfUnclaimed()
        XCTAssertEqual(title(nowPlaying), "Signal call")

        nowPlaying.nowPlayingInfo = [MPMediaItemPropertyTitle: "Voice message"]
        trigger.stop()
        XCTAssertEqual(title(nowPlaying), "Voice message")
    }
}

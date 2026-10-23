//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

@available(iOS 17.0, *)
final class CallMuteShortcutsTest: XCTestCase {
    func testMuteIntentsRunWithoutOpeningApp() {
        XCTAssertFalse(ToggleMicrophoneMuteIntent.openAppWhenRun)
        XCTAssertFalse(SetMicrophoneMuteIntent.openAppWhenRun)
        XCTAssertFalse(GetMicrophoneMuteStateIntent.openAppWhenRun)
        XCTAssertFalse(GetActiveCallStateIntent.openAppWhenRun)
    }

    func testCallMuteIntentDiscoverability() {
        XCTAssertTrue(ToggleMicrophoneMuteIntent.isDiscoverable)
        XCTAssertTrue(SetMicrophoneMuteIntent.isDiscoverable)
        XCTAssertTrue(GetMicrophoneMuteStateIntent.isDiscoverable)
        XCTAssertTrue(GetActiveCallStateIntent.isDiscoverable)
    }

    func testCallMuteShortcutErrorDescriptions() {
        XCTAssertEqual(CallMuteShortcutError.noActiveCall.errorDescription, "No active call.")
        XCTAssertEqual(CallMuteShortcutError.callEnded.errorDescription, "The call has already ended.")
        XCTAssertEqual(CallMuteShortcutError.unableToChangeMuteState.errorDescription, "Unable to change microphone mute state right now.")
    }
}

//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AppIntents
import Foundation

/// The action behind the Control Center mute toggle (`CallMuteControl`).
///
/// This file is compiled into both the app and the SignalControls extension.
/// As a `LiveActivityIntent`, it runs in the app's process, where the call is.
@available(iOS 17.0, *)
struct SetCallMuteControlIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Mute Call"
    // Shortcuts already has "Set Microphone Mute"; don't list this one too.
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Muted")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try await setMuted(value)
        return .result()
    }

#if SIGNAL_CONTROLS_EXTENSION
    private enum NotInAppError: LocalizedError {
        case notInApp
        var errorDescription: String? { "Open Signal to change mute." }
    }

    private func setMuted(_ isMuted: Bool) async throws {
        // Only reached if the system runs the intent in the extension.
        throw NotInAppError.notInApp
    }
#else
    private func setMuted(_ isMuted: Bool) async throws {
        try await CallMuteController.live().setMuted(isMuted)
    }
#endif
}

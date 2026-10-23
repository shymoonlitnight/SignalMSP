//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action Button toggle for microphone mute
/// during a call.
struct CallMuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CallMuteControlState.controlKind, provider: Provider()) { isMuted in
            ControlWidgetToggle("Mute Call", isOn: isMuted, action: SetCallMuteControlIntent()) { isOn in
                Label(isOn ? "Muted" : "Unmuted", systemImage: isOn ? "mic.slash.fill" : "mic.fill")
            }
        }
        .displayName("Mute Call")
        .description("Mute or unmute your microphone during a Signal call.")
    }
}

extension CallMuteControl {
    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            // Written by the app whenever the call or its mute state changes.
            return CallMuteControlState.isMuted
        }
    }
}

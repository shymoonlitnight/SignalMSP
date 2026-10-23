//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Hardware keys that toggle microphone mute on the call screen: Space,
/// the arrow keys, and Page Up/Down. Bluetooth keyboards, page turners and
/// foot pedals in keyboard mode send these.
///
/// The commands don't take priority over system behavior, so Full Keyboard
/// Access can still use these keys to move between and activate controls.
enum CallMuteKeyCommands {
    static let inputs: [String] = [
        " ",
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        UIKeyCommand.inputLeftArrow,
        UIKeyCommand.inputRightArrow,
        UIKeyCommand.inputPageUp,
        UIKeyCommand.inputPageDown,
    ]

    static func make(action: Selector) -> [UIKeyCommand] {
        return inputs.map { input in
            // Only Space is listed in the iPad keyboard shortcuts overlay;
            // the other keys are alternatives for page turners.
            let title: String? = input == " " ? OWSLocalizedString(
                "KEY_COMMAND_TOGGLE_MUTE",
                comment: "A keyboard command, on the call screen, to mute or unmute the microphone.",
            ) : nil
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.discoverabilityTitle = title
            // Holding a key (or a pedal) shouldn't toggle mute over and over.
            if #available(iOS 26, *) {
                command.repeatBehavior = .nonRepeatable
            }
            return command
        }
    }

    /// Presses closer together than this count as one, for key repeat on
    /// older iOS and for pedals that bounce or send duplicate key-downs.
    static let debounceInterval: TimeInterval = 0.3

    @MainActor
    private static var lastToggleTime: TimeInterval?

    /// Whether a press at `time` should toggle, given the last one that did.
    static func shouldToggle(at time: TimeInterval, lastToggleTime: TimeInterval?) -> Bool {
        guard let lastToggleTime else {
            return true
        }
        return time - lastToggleTime >= debounceInterval
    }

    @MainActor
    static func toggleMute() {
        let time = ProcessInfo.processInfo.systemUptime
        guard shouldToggle(at: time, lastToggleTime: lastToggleTime) else {
            return
        }
        lastToggleTime = time
        Task { @MainActor in
            do {
                try await CallMuteController.live().toggle()
            } catch {
                Logger.warn("Couldn't toggle mute from a key command: \(error)")
            }
        }
    }
}

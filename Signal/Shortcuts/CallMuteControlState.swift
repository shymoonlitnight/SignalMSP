//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Call mute state shared between the app, which writes it, and the
/// SignalControls extension, which shows it in the Control Center toggle.
///
/// This file is compiled into both the app and the extension.
enum CallMuteControlState {
    static let controlKind = "org.signal.CallMuteControl"

    private static let isMutedKey = "CallMuteControl.isMuted"

    /// The production App Group. The app has access to it in staging builds too.
    private static var defaults: UserDefaults? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "OWSBundleIDPrefix") as? String else {
            return nil
        }
        return UserDefaults(suiteName: "group.\(prefix).signal.group")
    }

    /// True while a call is active and its microphone is muted. Only the app
    /// clears it, so if the app is killed mid-call while muted it stays true
    /// until Signal next launches.
    static var isMuted: Bool {
        get { defaults?.bool(forKey: isMutedKey) ?? false }
        set { defaults?.set(newValue, forKey: isMutedKey) }
    }
}

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
    private static let updatedAtKey = "CallMuteControl.updatedAt"

    /// The app re-stores the state this often during a call, and the control
    /// treats a muted state older than `staleAfter` as left over from an app
    /// that was killed mid-call.
    static let refreshInterval: TimeInterval = 60
    static let staleAfter: TimeInterval = 180

    /// The production App Group. The app has access to it in staging builds too.
    private static let defaults: UserDefaults? = {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "OWSBundleIDPrefix") as? String else {
            return nil
        }
        return UserDefaults(suiteName: "group.\(prefix).signal.group")
    }()

    /// True while a call is active and its microphone is muted. Only the app
    /// writes it; each write also records when, for `displayedIsMuted`.
    static var isMuted: Bool {
        get { defaults?.bool(forKey: isMutedKey) ?? false }
        set {
            defaults?.set(newValue, forKey: isMutedKey)
            defaults?.set(Date().timeIntervalSince1970, forKey: updatedAtKey)
        }
    }

    /// When `isMuted` was last written (seconds since 1970), if ever.
    static var updatedAt: TimeInterval? {
        return defaults?.object(forKey: updatedAtKey) as? TimeInterval
    }

    /// What the control shows: `isMuted`, unless it hasn't been refreshed
    /// recently, e.g. because the app was killed mid-call while muted.
    static var displayedIsMuted: Bool {
        return displayedValue(isMuted: isMuted, updatedAt: updatedAt, now: Date().timeIntervalSince1970)
    }

    static func displayedValue(isMuted: Bool, updatedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard isMuted, let updatedAt else {
            return false
        }
        return now - updatedAt <= staleAfter
    }
}

//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// SignalMSP fork only (mute-triggers branch). Not intended for upstream.

import os
import SignalServiceKit

/// Logs to Signal's debug log and to the unified system log, so fork
/// messages can be watched live in Console.app (subsystem "SignalMSP").
enum ForkLog {
    private static let systemLog = os.Logger(subsystem: "SignalMSP", category: "MuteTriggers")

    static func info(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        SignalServiceKit.Logger.info(message, file: file, function: function, line: line)
        systemLog.notice("\(message, privacy: .public)")
    }

    static func warn(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        SignalServiceKit.Logger.warn(message, file: file, function: function, line: line)
        systemLog.warning("\(message, privacy: .public)")
    }
}

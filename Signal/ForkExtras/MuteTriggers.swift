//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// SignalMSP fork only (mute-triggers branch). Not intended for upstream.

import Foundation
import SignalServiceKit

/// Something outside the app that can toggle call mute, such as a media
/// remote's track-skip buttons. Each source has an on/off switch in the iOS
/// Settings app (Signal/Settings.bundle), off by default.
@MainActor
protocol MuteTriggerSource: AnyObject {
    /// Name used in logs.
    var name: String { get }
    /// Starts listening; call `onTrigger` each time mute should toggle.
    func start(onTrigger: @escaping @MainActor () -> Void)
    func stop()
}

/// Starts the enabled trigger sources when a call begins and stops them when
/// it ends. Every source toggles mute through one debounced path, so two
/// sources firing for the same press don't cancel each other out.
@MainActor
final class MuteTriggerCoordinator: CallServiceStateObserver {
    struct SourceEntry {
        /// UserDefaults key written by the Settings app switch.
        let settingKey: String
        let make: @MainActor () -> MuteTriggerSource
    }

    static let allSources: [SourceEntry] = [
        SourceEntry(settingKey: TrackSkipMuteTrigger.settingKey, make: { TrackSkipMuteTrigger() }),
        SourceEntry(settingKey: HeadTiltMuteTrigger.settingKey, make: { HeadTiltMuteTrigger() }),
    ]

    /// Triggers closer together than this count as one press.
    static let debounceInterval: TimeInterval = 0.3

    private let sources: [SourceEntry]
    private let isEnabled: (String) -> Bool
    private let toggleMute: @MainActor () async throws -> Bool
    private let now: () -> TimeInterval

    private var running: [MuteTriggerSource] = []
    private var lastTriggerTime: TimeInterval?

    init(
        sources: [SourceEntry] = MuteTriggerCoordinator.allSources,
        isEnabled: @escaping (String) -> Bool = { UserDefaults.standard.bool(forKey: $0) },
        toggleMute: @escaping @MainActor () async throws -> Bool = { try await CallMuteController.live().toggle() },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.sources = sources
        self.isEnabled = isEnabled
        self.toggleMute = toggleMute
        self.now = now
    }

    var runningSourceNames: [String] { running.map(\.name) }

    // MARK: - CallServiceStateObserver

    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        if newValue != nil {
            callStarted()
        } else {
            callEnded()
        }
    }

    // MARK: -

    /// Starts the enabled sources, unless they're already running. Settings
    /// are read here, so changes apply from the next call.
    func callStarted() {
        guard running.isEmpty else {
            return
        }
        running = sources.filter { isEnabled($0.settingKey) }.map { $0.make() }
        for source in running {
            let name = source.name
            source.start { [weak self] in
                self?.trigger(from: name)
            }
        }
        if !running.isEmpty {
            ForkLog.info("MuteTriggers: started \(runningSourceNames)")
        }
    }

    func callEnded() {
        guard !running.isEmpty else {
            return
        }
        ForkLog.info("MuteTriggers: stopping \(runningSourceNames)")
        running.forEach { $0.stop() }
        running = []
        lastTriggerTime = nil
    }

    func trigger(from sourceName: String) {
        let time = now()
        if let lastTriggerTime, time - lastTriggerTime < Self.debounceInterval {
            ForkLog.info("MuteTriggers: ignored \(sourceName) (debounce)")
            return
        }
        lastTriggerTime = time

        Task { @MainActor in
            do {
                let isMuted = try await toggleMute()
                ForkLog.info("MuteTriggers: \(sourceName) toggled mute to \(isMuted)")
            } catch {
                ForkLog.warn("MuteTriggers: \(sourceName) couldn't toggle mute: \(error)")
            }
        }
    }
}

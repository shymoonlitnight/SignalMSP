//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

@MainActor
final class MuteTriggerCoordinatorTest: XCTestCase {
    private final class FakeSource: MuteTriggerSource {
        let name: String
        var isRunning = false
        var onTrigger: (@MainActor () -> Void)?

        init(name: String) {
            self.name = name
        }

        func start(onTrigger: @escaping @MainActor () -> Void) {
            isRunning = true
            self.onTrigger = onTrigger
        }

        func stop() {
            isRunning = false
            onTrigger = nil
        }

        func fire() {
            onTrigger?()
        }
    }

    private var clock: TimeInterval = 100
    private var toggles = 0
    private var enabledKeys: Set<String> = []
    private var made: [String: FakeSource] = [:]

    private func makeCoordinator(keys: [String]) -> MuteTriggerCoordinator {
        let sources = keys.map { key in
            MuteTriggerCoordinator.SourceEntry(settingKey: key, make: { [unowned self] in
                let source = FakeSource(name: key)
                self.made[key] = source
                return source
            })
        }
        return MuteTriggerCoordinator(
            sources: sources,
            isEnabled: { [unowned self] in self.enabledKeys.contains($0) },
            toggleMute: { [unowned self] in
                self.toggles += 1
                return self.toggles % 2 == 1
            },
            now: { [unowned self] in self.clock },
        )
    }

    /// Lets the coordinator's toggle task run.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    func testStartsOnlyEnabledSourcesAndStopsAtCallEnd() {
        enabledKeys = ["a"]
        let coordinator = makeCoordinator(keys: ["a", "b"])

        coordinator.callStarted()
        XCTAssertEqual(coordinator.runningSourceNames, ["a"])
        XCTAssertEqual(made["a"]?.isRunning, true)
        XCTAssertNil(made["b"], "disabled sources aren't created")

        // A second update during the same call doesn't restart anything.
        let first = made["a"]
        coordinator.callStarted()
        XCTAssertTrue(made["a"] === first)

        coordinator.callEnded()
        XCTAssertEqual(coordinator.runningSourceNames, [])
        XCTAssertEqual(first?.isRunning, false)
    }

    func testNothingEnabledStartsNothing() {
        let coordinator = makeCoordinator(keys: ["a"])
        coordinator.callStarted()
        XCTAssertEqual(coordinator.runningSourceNames, [])
        XCTAssertNil(made["a"])
    }

    func testSourceTriggerTogglesMute() async {
        enabledKeys = ["a"]
        let coordinator = makeCoordinator(keys: ["a"])
        coordinator.callStarted()

        made["a"]?.fire()
        await settle()
        XCTAssertEqual(toggles, 1)

        coordinator.callEnded()
        made["a"]?.fire() // stopped sources no longer reach the coordinator
        await settle()
        XCTAssertEqual(toggles, 1)
    }

    func testDebounceIgnoresTriggersCloseTogether() async {
        let coordinator = makeCoordinator(keys: [])

        coordinator.trigger(from: "a")
        clock += 0.1
        coordinator.trigger(from: "b")
        clock += MuteTriggerCoordinator.debounceInterval
        coordinator.trigger(from: "a")
        await settle()

        XCTAssertEqual(toggles, 2)
    }

    func testDefaultSourcesIncludeTrackSkip() {
        XCTAssertEqual(MuteTriggerCoordinator.allSources.map(\.settingKey), [TrackSkipMuteTrigger.settingKey])
    }
}

//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal

@MainActor
final class CallMuteControllerTest: XCTestCase {
    private final class FakeCall: CallMuteTarget {
        enum Behavior {
            /// Mute changes apply as soon as they're requested.
            case immediate
            /// Mute changes apply after this many polls.
            case afterPolls(Int)
            /// Mute changes never apply.
            case never
        }

        var isMuted: Bool
        var hasEnded = false
        var isCurrent = true
        var isRingingUnanswered = false
        var behavior: Behavior
        var requested: [Bool] = []
        var reportedToSystem: [Bool] = []
        private var pendingPolls = 0
        private var pendingState: Bool?

        init(isMuted: Bool, behavior: Behavior = .immediate) {
            self.isMuted = isMuted
            self.behavior = behavior
        }

        func requestMuted(_ isMuted: Bool) {
            requested.append(isMuted)
            switch behavior {
            case .immediate:
                self.isMuted = isMuted
            case .afterPolls(let polls):
                pendingState = isMuted
                pendingPolls = polls
                Task { @MainActor in await self.applyPending() }
            case .never:
                break
            }
        }

        func reportMutedToSystem(_ isMuted: Bool) {
            reportedToSystem.append(isMuted)
        }

        private func applyPending() async {
            while pendingPolls > 0 {
                pendingPolls -= 1
                try? await Task.sleep(nanoseconds: NSEC_PER_MSEC)
            }
            if let pendingState {
                isMuted = pendingState
            }
        }
    }

    private var feedback: [Bool] = []
    private var clock: TimeInterval = 100

    /// Debounce is off unless a test asks for it, so tests can toggle back to back.
    private func makeController(call: FakeCall?, debounceInterval: TimeInterval = 0) -> CallMuteController {
        feedback = []
        return CallMuteController(
            currentCall: { call },
            feedback: { [weak self] in self?.feedback.append($0) },
            pollIntervalNanoseconds: NSEC_PER_MSEC,
            maxPolls: 50,
            debounceInterval: debounceInterval,
            now: { [unowned self] in self.clock },
        )
    }

    func testToggleFlipsMuteReportsToSystemAndGivesFeedback() async throws {
        let call = FakeCall(isMuted: false)
        let controller = makeController(call: call)

        let muted = try await controller.toggle()
        XCTAssertTrue(muted)
        XCTAssertTrue(call.isMuted)

        let unmuted = try await controller.toggle()
        XCTAssertFalse(unmuted)

        XCTAssertEqual(call.requested, [true, false])
        XCTAssertEqual(call.reportedToSystem, [true, false])
        XCTAssertEqual(feedback, [true, false])
    }

    func testSetMutedToSameStateSucceeds() async throws {
        let call = FakeCall(isMuted: true)
        let controller = makeController(call: call)

        let muted = try await controller.setMuted(true)
        XCTAssertTrue(muted)
        XCTAssertEqual(call.reportedToSystem, [true])
    }

    func testWaitsForAsynchronousMuteChange() async throws {
        let call = FakeCall(isMuted: false, behavior: .afterPolls(5))
        let controller = makeController(call: call)

        let muted = try await controller.setMuted(true)
        XCTAssertTrue(muted)
        XCTAssertEqual(call.reportedToSystem, [true])
    }

    func testMuteChangeThatNeverAppliesThrowsWithoutReportingOrFeedback() async {
        let call = FakeCall(isMuted: false, behavior: .never)
        let controller = makeController(call: call)

        await assertThrows(.unableToChangeMuteState) { try await controller.toggle() }
        XCTAssertEqual(call.requested, [true])
        XCTAssertEqual(call.reportedToSystem, [])
        XCTAssertEqual(feedback, [])
    }

    func testCallEndingDuringWaitDoesNotReportOrGiveFeedback() async {
        let call = FakeCall(isMuted: false, behavior: .afterPolls(3))
        let controller = makeController(call: call)

        // Runs once toggle() first waits for the change to apply.
        Task { @MainActor in call.hasEnded = true }
        await assertThrows(.callEnded) { try await controller.toggle() }
        XCTAssertEqual(call.requested, [true])
        XCTAssertEqual(call.reportedToSystem, [])
        XCTAssertEqual(feedback, [])
    }

    func testCallReplacedDuringWaitDoesNotReport() async {
        let call = FakeCall(isMuted: false, behavior: .afterPolls(3))
        let controller = makeController(call: call)

        Task { @MainActor in call.isCurrent = false }
        await assertThrows(.callEnded) { try await controller.setMuted(true) }
        XCTAssertEqual(call.reportedToSystem, [])
        XCTAssertEqual(feedback, [])
    }

    func testTogglesCloseTogetherCountOnce() async throws {
        let call = FakeCall(isMuted: false)
        let controller = makeController(call: call, debounceInterval: 0.3)

        let first = try await controller.toggle()
        clock += 0.1
        // Ignored: returns the current state without requesting a change.
        let second = try await controller.toggle()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(call.requested, [true])
        XCTAssertEqual(feedback, [true])
    }

    func testTogglesFarEnoughApartBothApply() async throws {
        let call = FakeCall(isMuted: false)
        let controller = makeController(call: call, debounceInterval: 0.3)
        clock = 0 // so 0.3 later is exactly 0.3 apart in floating point

        let first = try await controller.toggle()
        clock += 0.3
        let second = try await controller.toggle()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(call.requested, [true, false])
    }

    func testSetMutedRightAfterToggleIsNotDropped() async throws {
        let call = FakeCall(isMuted: true)
        let controller = makeController(call: call, debounceInterval: 0.3)

        let toggled = try await controller.toggle()
        let set = try await controller.setMuted(true)
        XCTAssertFalse(toggled)
        XCTAssertTrue(set)
        XCTAssertEqual(call.requested, [false, true])
    }

    func testToggleWhileAChangeIsInProgressIsIgnored() async throws {
        let call = FakeCall(isMuted: false, behavior: .afterPolls(5))
        let controller = makeController(call: call)

        async let first = controller.setMuted(true)
        // Let setMuted start and begin waiting before toggling.
        while call.requested.isEmpty {
            await Task.yield()
        }
        let second = try await controller.toggle()
        let firstResult = try await first
        XCTAssertFalse(second, "returns the state before the pending change")
        XCTAssertTrue(firstResult)
        XCTAssertEqual(call.requested, [true])
    }

    func testNoActiveCall() async {
        let controller = makeController(call: nil)

        XCTAssertFalse(controller.hasActiveCall)
        XCTAssertThrowsError(try controller.isMuted()) { XCTAssertEqual($0 as? CallMuteError, .noActiveCall) }
        await assertThrows(.noActiveCall) { try await controller.toggle() }
        await assertThrows(.noActiveCall) { try await controller.setMuted(true) }
    }

    func testEndedCall() async {
        let call = FakeCall(isMuted: false)
        call.hasEnded = true
        let controller = makeController(call: call)

        XCTAssertFalse(controller.hasActiveCall)
        XCTAssertThrowsError(try controller.isMuted()) { XCTAssertEqual($0 as? CallMuteError, .callEnded) }
        await assertThrows(.callEnded) { try await controller.toggle() }
        XCTAssertEqual(call.requested, [])
    }

    func testRingingUnansweredCallCannotBeChanged() async {
        let call = FakeCall(isMuted: false)
        call.isRingingUnanswered = true
        let controller = makeController(call: call)

        XCTAssertTrue(controller.hasActiveCall)
        XCTAssertFalse(try controller.isMuted())
        await assertThrows(.callNotAnswered) { try await controller.toggle() }
        await assertThrows(.callNotAnswered) { try await controller.setMuted(true) }
        XCTAssertEqual(call.requested, [])
    }

    func testIsMutedAndHasActiveCall() throws {
        let call = FakeCall(isMuted: true)
        let controller = makeController(call: call)

        XCTAssertTrue(controller.hasActiveCall)
        XCTAssertTrue(try controller.isMuted())
    }

    func testIsRingingUnansweredForEveryCallState() {
        let ringing: [CallState] = [.localRinging_Anticipatory, .localRinging_ReadyToAnswer]
        let notRinging: [CallState] = [
            .idle, .dialing, .answering, .remoteRinging, .accepting, .connected, .reconnecting,
            .localFailure, .localHangup, .remoteHangup, .remoteHangupNeedPermission,
            .remoteBusy, .answeredElsewhere, .declinedElsewhere, .busyElsewhere,
        ]
        for state in ringing {
            XCTAssertTrue(CallMuteController.isRingingUnanswered(state), "\(state)")
        }
        for state in notRinging {
            XCTAssertFalse(CallMuteController.isRingingUnanswered(state), "\(state)")
        }
    }

    func testCanApplyDirectly() {
        // Muting never needs the microphone.
        XCTAssertTrue(CallMuteController.canApplyDirectly(isMuted: true, recordPermission: .granted))
        XCTAssertTrue(CallMuteController.canApplyDirectly(isMuted: true, recordPermission: .denied))
        XCTAssertTrue(CallMuteController.canApplyDirectly(isMuted: true, recordPermission: .undetermined))
        // Unmuting does.
        XCTAssertTrue(CallMuteController.canApplyDirectly(isMuted: false, recordPermission: .granted))
        XCTAssertFalse(CallMuteController.canApplyDirectly(isMuted: false, recordPermission: .denied))
        XCTAssertFalse(CallMuteController.canApplyDirectly(isMuted: false, recordPermission: .undetermined))
    }

    func testErrorDescriptions() {
        XCTAssertEqual(CallMuteError.noActiveCall.errorDescription, "No active call.")
        XCTAssertEqual(CallMuteError.callEnded.errorDescription, "The call has already ended.")
        XCTAssertEqual(CallMuteError.callNotAnswered.errorDescription, "The call hasn't been answered yet.")
        XCTAssertEqual(CallMuteError.unableToChangeMuteState.errorDescription, "Unable to change microphone mute state right now.")
    }

    private func assertThrows(
        _ expected: CallMuteError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () async throws -> Bool,
    ) async {
        do {
            _ = try await work()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CallMuteError, expected, file: file, line: line)
        }
    }
}

// MARK: -

final class CallMuteKeyCommandsTest: XCTestCase {
    func testKeyCommands() {
        let commands = CallMuteKeyCommands.make(action: #selector(NSObject.description))

        XCTAssertEqual(commands.map(\.input), CallMuteKeyCommands.inputs)
        XCTAssertTrue(commands.allSatisfy { $0.modifierFlags.isEmpty })
        // Full Keyboard Access keeps priority for Space and the arrow keys.
        XCTAssertTrue(commands.allSatisfy { !$0.wantsPriorityOverSystemBehavior })
        // Only Space is listed in the keyboard shortcuts overlay.
        XCTAssertEqual(commands.filter { $0.discoverabilityTitle != nil }.map(\.input), [" "])
        if #available(iOS 26, *) {
            XCTAssertTrue(commands.allSatisfy { $0.repeatBehavior == .nonRepeatable })
        }
    }
}

// MARK: -

@MainActor
final class CallMuteControlUpdaterTest: XCTestCase {
    func testPublishesUnmutedWithoutACallAndSkipsRepeats() {
        var stored: [Bool] = []
        var reloads = 0
        let updater = CallMuteControlUpdater(store: { stored.append($0) }, reloadControl: { reloads += 1 })

        // Registering clears any state left over from a previous run.
        updater.didUpdateCall(from: nil, to: nil)
        updater.didUpdateCall(from: nil, to: nil)

        XCTAssertEqual(stored, [false])
        XCTAssertEqual(reloads, 1)
        XCTAssertFalse(CallMuteControlUpdater.isMuted(for: nil))
    }

    func testRefreshStoresTheCurrentValueWithoutReloading() {
        var stored: [Bool] = []
        var reloads = 0
        let updater = CallMuteControlUpdater(store: { stored.append($0) }, reloadControl: { reloads += 1 })
        updater.didUpdateCall(from: nil, to: nil)

        updater.refresh()
        XCTAssertEqual(stored, [false, false])
        XCTAssertEqual(reloads, 1)
    }
}

// MARK: -

final class CallMuteControlStateTest: XCTestCase {
    func testStaleMutedStateShowsUnmuted() {
        let now: TimeInterval = 1_000_000
        let staleAfter = CallMuteControlState.staleAfter

        XCTAssertTrue(CallMuteControlState.displayedValue(isMuted: true, updatedAt: now - 10, now: now))
        XCTAssertTrue(CallMuteControlState.displayedValue(isMuted: true, updatedAt: now - staleAfter, now: now))
        XCTAssertFalse(CallMuteControlState.displayedValue(isMuted: true, updatedAt: now - staleAfter - 1, now: now))
        XCTAssertFalse(CallMuteControlState.displayedValue(isMuted: true, updatedAt: nil, now: now))
        XCTAssertFalse(CallMuteControlState.displayedValue(isMuted: false, updatedAt: now, now: now))
    }

    func testRefreshesWellWithinTheStaleTime() {
        XCTAssertLessThan(CallMuteControlState.refreshInterval * 2, CallMuteControlState.staleAfter)
    }
}

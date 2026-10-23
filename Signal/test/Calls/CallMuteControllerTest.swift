//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

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

    private func makeController(call: FakeCall?) -> CallMuteController {
        feedback = []
        return CallMuteController(
            currentCall: { call },
            feedback: { [weak self] in self?.feedback.append($0) },
            pollIntervalNanoseconds: NSEC_PER_MSEC,
            maxPolls: 50,
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

    func testRepeatedPressesAreDebounced() {
        XCTAssertTrue(CallMuteKeyCommands.shouldToggle(at: 10, lastToggleTime: nil))
        XCTAssertFalse(CallMuteKeyCommands.shouldToggle(at: 10.1, lastToggleTime: 10))
        XCTAssertTrue(CallMuteKeyCommands.shouldToggle(at: 10.3, lastToggleTime: 10))
    }
}

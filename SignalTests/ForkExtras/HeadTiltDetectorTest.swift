//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class HeadTiltDetectorTest: XCTestCase {
    private let sampleInterval: TimeInterval = 0.04 // 25 samples/s

    /// Feeds `angle` for `duration` seconds starting at `time`; returns the events.
    private func feed(
        _ detector: inout HeadTiltDetector,
        angle: Double,
        for duration: TimeInterval,
        from time: inout TimeInterval,
    ) -> [HeadTiltDetector.Event] {
        var events: [HeadTiltDetector.Event] = []
        let end = time + duration
        while time < end {
            events += detector.process(angle: angle, at: time)
            time += sampleInterval
        }
        return events
    }

    private func triggerCount(_ events: [HeadTiltDetector.Event]) -> Int {
        events.filter { $0 == .triggered }.count
    }

    private func movements(_ events: [HeadTiltDetector.Event]) -> [(peak: Double, heldFor: TimeInterval, triggered: Bool)] {
        events.compactMap {
            if case .movement(let peak, let heldFor, let triggered) = $0 {
                return (peak, heldFor, triggered)
            }
            return nil
        }
    }

    func testHeldTiltTriggersOnceAndReportsTheMovement() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        XCTAssertEqual(feed(&detector, angle: 0, for: 1, from: &time), [])

        // Holding a right tilt for a long time still triggers only once.
        XCTAssertEqual(feed(&detector, angle: 0.5, for: 2, from: &time), [.triggered])

        // Coming back reports the movement's peak.
        let back = movements(feed(&detector, angle: 0, for: 1, from: &time))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.peak ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(back.first?.triggered, true)
        XCTAssertEqual(back.first?.heldFor ?? 0, 0.5, accuracy: 0.05)

        // A held left tilt triggers too.
        XCTAssertEqual(triggerCount(feed(&detector, angle: -0.6, for: 1, from: &time)), 1)
    }

    func testBothSidesUseTheSameAngle() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)

        // ~17° doesn't trigger on either side; ~23° does on both.
        XCTAssertEqual(triggerCount(feed(&detector, angle: -0.3, for: 1, from: &time)), 0)
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.3, for: 1, from: &time)), 0)
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: -0.4, for: 1, from: &time)), 1)
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.4, for: 1, from: &time)), 1)
    }

    func testBriefTiltOnlyReportsTheMovement() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(feed(&detector, angle: 0.6, for: 0.3, from: &time), [])

        let back = movements(feed(&detector, angle: 0, for: 0.5, from: &time))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.triggered, false)
        XCTAssertEqual(back.first?.heldFor ?? 0, 0.3, accuracy: 0.05)
    }

    func testSmallMovementsDoNothing() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(feed(&detector, angle: 0.15, for: 3, from: &time), [])
        XCTAssertEqual(feed(&detector, angle: 0, for: 1, from: &time), [])
    }

    func testSlowDriftDoesNotTrigger() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        var events: [HeadTiltDetector.Event] = []
        // Drift to a 31° lean over 20 s, e.g. a long bend on a bike. The
        // baseline stops at 15°, so this stays under the 20° trigger angle.
        for step in 0..<500 {
            events += detector.process(angle: 0.55 * Double(step) / 500, at: time)
            time += sampleInterval
        }
        XCTAssertEqual(triggerCount(events), 0)
        // The baseline followed, but no further than ~15° from upright.
        XCTAssertEqual(detector.baseline, detector.maxBaselineOffset, accuracy: 0.01)
    }

    func testQuickTiltDoesNotDragTheBaseline() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)

        // Tilt right to ~29° over half a second, then hold.
        var events: [HeadTiltDetector.Event] = []
        for step in 1...12 {
            events += detector.process(angle: 0.5 * Double(step) / 12, at: time)
            time += sampleInterval
        }
        events += feed(&detector, angle: 0.5, for: 1, from: &time)

        XCTAssertEqual(triggerCount(events), 1)
        XCTAssertLessThan(detector.baseline, 0.05)
    }

    func testStartsFromATiltedHeadWithoutGettingStuck() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        // The call starts with the head tilted 40°; the baseline only goes to 15°.
        _ = feed(&detector, angle: 0.7, for: 0.04, from: &time)
        XCTAssertEqual(detector.baseline, detector.maxBaselineOffset, accuracy: 0.01)

        // Upright, then a held tilt the other way triggers.
        _ = feed(&detector, angle: 0, for: 2, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: -0.6, for: 1, from: &time)), 1)

        // Back to true upright re-arms, even if that's not near the baseline.
        _ = feed(&detector, angle: 0, for: 0.2, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: -0.6, for: 1, from: &time)), 1)
    }

    func testBaselineThatIsOffRecovers() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        // Starts 15° off (head tilted when the call began), then upright.
        _ = feed(&detector, angle: 0.7, for: 0.04, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0, for: 30, from: &time)), 0)
        XCTAssertLessThan(abs(detector.baseline), 0.05)
    }

    func testCallStartingWithTheHeadTiltedDoesNotTrigger() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        // Lying on one side when the call starts: ~80° for a long time.
        XCTAssertEqual(triggerCount(feed(&detector, angle: 1.4, for: 10, from: &time)), 0)
        XCTAssertEqual(triggerCount(feed(&detector, angle: -1.4, for: 10, from: &time)), 0)

        // Sitting up arms it.
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.6, for: 1, from: &time)), 1)
    }

    func testHoldingATiltTowardUprightFromALeaningBaselineTriggersOnce() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        // Resting posture leans ~9° left, then a held tilt right to ~13°,
        // which is near true upright but ~22° from the baseline.
        _ = feed(&detector, angle: -0.15, for: 5, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.22, for: 3, from: &time)), 1)
    }

    func testTiltFromBeforeAGapInSamplesDoesNotTrigger() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        // A brief tilt (taking an AirPod out), then no samples for a minute.
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.6, for: 0.2, from: &time)), 0)
        time += 60
        // Samples resume with the head still tilted: that's not a held tilt.
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.6, for: 2, from: &time)), 0)

        // Upright again, and a held tilt works as usual.
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(triggerCount(feed(&detector, angle: 0.7, for: 1, from: &time)), 1)
    }
}

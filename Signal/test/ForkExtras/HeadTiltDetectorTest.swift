//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class HeadTiltDetectorTest: XCTestCase {
    private let sampleInterval: TimeInterval = 0.04 // 25 samples/s, like AirPods

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
            if let event = detector.process(angle: angle, at: time) {
                events.append(event)
            }
            time += sampleInterval
        }
        return events
    }

    func testHeldTiltTriggersOnce() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        XCTAssertEqual(feed(&detector, angle: 0, for: 1, from: &time), [])

        // Holding the tilt for a long time still triggers only once.
        XCTAssertEqual(feed(&detector, angle: 0.8, for: 2, from: &time), [.triggered])

        // Coming back upright and tilting again triggers again.
        XCTAssertEqual(feed(&detector, angle: 0, for: 1, from: &time), [])
        XCTAssertEqual(feed(&detector, angle: -0.8, for: 1, from: &time), [.triggered])
    }

    func testBriefTiltIsANearMiss() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(feed(&detector, angle: 0.8, for: 0.3, from: &time), [])

        let events = feed(&detector, angle: 0, for: 0.5, from: &time)
        XCTAssertEqual(events.count, 1)
        guard case .nearMiss(let heldFor)? = events.first else {
            return XCTFail("expected a near miss, got \(events)")
        }
        XCTAssertLessThan(heldFor, 0.5)
    }

    func testSmallTiltsDoNothing() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, angle: 0, for: 1, from: &time)
        XCTAssertEqual(feed(&detector, angle: 0.4, for: 3, from: &time), [])
    }

    func testSlowDriftDoesNotTrigger() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        var events: [HeadTiltDetector.Event] = []
        // Drift to a 34° lean over 20 s, e.g. a long bend on a bike.
        for step in 0..<500 {
            if let event = detector.process(angle: 0.6 * Double(step) / 500, at: time) {
                events.append(event)
            }
            time += sampleInterval
        }
        XCTAssertEqual(events, [])
        // The baseline followed, but no further than ~15° from upright.
        XCTAssertEqual(detector.baseline, detector.maxBaselineOffset, accuracy: 0.01)
    }

    func testStartsFromATiltedHeadWithoutGettingStuck() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        // The call starts with the head tilted 40°; the baseline only goes to 15°.
        _ = feed(&detector, angle: 0.7, for: 0.04, from: &time)
        XCTAssertEqual(detector.baseline, detector.maxBaselineOffset, accuracy: 0.01)

        // Upright, then a held tilt the other way triggers.
        _ = feed(&detector, angle: 0, for: 2, from: &time)
        XCTAssertEqual(feed(&detector, angle: -0.6, for: 1, from: &time), [.triggered])

        // Back to true upright re-arms, even if that's not near the baseline.
        _ = feed(&detector, angle: 0, for: 0.2, from: &time)
        XCTAssertEqual(feed(&detector, angle: -0.6, for: 1, from: &time), [.triggered])
    }
}

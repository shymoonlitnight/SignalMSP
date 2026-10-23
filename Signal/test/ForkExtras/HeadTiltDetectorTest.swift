//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class HeadTiltDetectorTest: XCTestCase {
    private let sampleInterval: TimeInterval = 0.04 // 25 samples/s, like AirPods

    /// Feeds `roll` for `duration` seconds starting at `time`; returns the events.
    private func feed(
        _ detector: inout HeadTiltDetector,
        roll: Double,
        for duration: TimeInterval,
        from time: inout TimeInterval,
    ) -> [HeadTiltDetector.Event] {
        var events: [HeadTiltDetector.Event] = []
        let end = time + duration
        while time < end {
            if let event = detector.process(roll: roll, at: time) {
                events.append(event)
            }
            time += sampleInterval
        }
        return events
    }

    func testHeldTiltTriggersOnce() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        XCTAssertEqual(feed(&detector, roll: 0, for: 1, from: &time), [])

        // Holding the tilt for a long time still triggers only once.
        XCTAssertEqual(feed(&detector, roll: 0.8, for: 2, from: &time), [.triggered])

        // Coming back upright and tilting again triggers again.
        XCTAssertEqual(feed(&detector, roll: 0, for: 1, from: &time), [])
        XCTAssertEqual(feed(&detector, roll: -0.8, for: 1, from: &time), [.triggered])
    }

    func testBriefTiltIsANearMiss() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, roll: 0, for: 1, from: &time)
        XCTAssertEqual(feed(&detector, roll: 0.8, for: 0.3, from: &time), [])

        let events = feed(&detector, roll: 0, for: 0.5, from: &time)
        XCTAssertEqual(events.count, 1)
        guard case .nearMiss(let heldFor)? = events.first else {
            return XCTFail("expected a near miss, got \(events)")
        }
        XCTAssertLessThan(heldFor, 0.5)
    }

    func testSmallTiltsDoNothing() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        _ = feed(&detector, roll: 0, for: 1, from: &time)
        XCTAssertEqual(feed(&detector, roll: 0.4, for: 3, from: &time), [])
    }

    func testSlowDriftFollowsBaseline() {
        var detector = HeadTiltDetector()
        var time: TimeInterval = 0
        var events: [HeadTiltDetector.Event] = []
        // Drift to a 46° lean over 20 s, e.g. a long bend on a bike.
        for step in 0..<500 {
            if let event = detector.process(roll: 0.8 * Double(step) / 500, at: time) {
                events.append(event)
            }
            time += sampleInterval
        }
        XCTAssertEqual(events, [])
        XCTAssertEqual(detector.baseline ?? 0, 0.8, accuracy: 0.1)
    }
}

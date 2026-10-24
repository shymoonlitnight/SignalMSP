//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// SignalMSP fork only (mute-triggers branch). Not intended for upstream.

import CoreMotion
import Foundation

/// Spots a deliberate sideways head tilt (ear toward shoulder) held for a
/// moment. Nods and head shakes are ignored, since people do both all the
/// time in conversation.
///
/// Input is the head's sideways tilt measured from gravity, so 0 is truly
/// upright and turning the head doesn't change it. Tilts are measured from a
/// baseline that slowly follows the head's resting posture, but stays within
/// `maxBaselineOffset` of upright so it can't drift away.
struct HeadTiltDetector {
    enum Event: Equatable {
        /// A tilt was held long enough; toggle mute.
        case triggered
        /// A tilt ended before it was held long enough (logged for tuning).
        case nearMiss(heldFor: TimeInterval)
    }

    /// How far from the baseline counts as tilted, in radians (~32°).
    var threshold: Double = 0.55
    /// After a trigger, the head must come back within this (~14°) of the
    /// baseline, or of true upright, before the next trigger.
    var rearmThreshold: Double = 0.25
    /// How long the tilt must be held.
    var holdDuration: TimeInterval = 0.5
    /// How quickly the baseline follows the resting posture.
    var baselineTimeConstant: TimeInterval = 3.0
    /// The baseline stays within this (~15°) of true upright.
    var maxBaselineOffset: Double = 0.26

    private(set) var baseline: Double = 0
    private var lastTime: TimeInterval?
    private var tiltStart: TimeInterval?
    private var isArmed = true

    /// Distance of the last sample from the baseline, in radians.
    private(set) var deviation: Double = 0

    mutating func process(angle: Double, at time: TimeInterval) -> Event? {
        guard let lastTime else {
            lastTime = time
            baseline = clampedBaseline(angle)
            deviation = abs(angle - baseline)
            return nil
        }
        let elapsed = max(0, time - lastTime)
        self.lastTime = time
        deviation = abs(angle - baseline)

        // After a trigger, wait for the head to come back. The baseline stays
        // put meanwhile, so holding the tilt can't trigger again.
        if !isArmed {
            if deviation < rearmThreshold || abs(angle) < rearmThreshold {
                isArmed = true
            }
            return nil
        }

        if deviation >= threshold {
            guard let tiltStart else {
                tiltStart = time
                return nil
            }
            if time - tiltStart >= holdDuration {
                self.tiltStart = nil
                isArmed = false
                return .triggered
            }
            return nil
        }

        var event: Event?
        if let tiltStart {
            event = .nearMiss(heldFor: time - tiltStart)
            self.tiltStart = nil
        }
        baseline = clampedBaseline(baseline + (angle - baseline) * min(1, elapsed / baselineTimeConstant))
        return event
    }

    private func clampedBaseline(_ value: Double) -> Double {
        min(maxBaselineOffset, max(-maxBaselineOffset, value))
    }
}

/// Toggles mute when the wearer holds a sideways head tilt, using head
/// tracking from AirPods (Pro, Max, 3rd gen and later) and Beats with
/// spatial audio. Needs Motion & Fitness permission (NSMotionUsageDescription).
@MainActor
final class HeadTiltMuteTrigger: MuteTriggerSource {
    static let settingKey = "MuteTrigger.headTilt"

    let name = "headTilt"
    private let manager = CMHeadphoneMotionManager()
    private var detector = HeadTiltDetector()

    // Periodic summary for tuning and for checking that updates keep
    // arriving while backgrounded or locked.
    private static let reportInterval: TimeInterval = 1
    private var samplesSinceReport = 0
    private var lastReportTime: TimeInterval?

    func start(onTrigger: @escaping @MainActor () -> Void) {
        guard manager.isDeviceMotionAvailable else {
            ForkLog.info("MuteTriggers: headTilt unavailable on this device")
            return
        }
        ForkLog.info("MuteTriggers: headTilt starting, motion permission \(Self.describe(CMHeadphoneMotionManager.authorizationStatus()))")
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                self?.handle(motion: motion, error: error, onTrigger: onTrigger)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        detector = HeadTiltDetector()
        samplesSinceReport = 0
        lastReportTime = nil
    }

    private func handle(motion: CMDeviceMotion?, error: Error?, onTrigger: @MainActor () -> Void) {
        if let error {
            ForkLog.warn("MuteTriggers: headTilt error \(error)")
            return
        }
        guard let motion else {
            return
        }
        let time = motion.timestamp
        // Gravity in the headphones' frame. Its component along the ear-to-ear
        // axis gives the sideways tilt; turning the head doesn't change it.
        let gravity = motion.gravity
        let sidewaysTilt = Self.tiltAngle(gravity.x)

        switch detector.process(angle: sidewaysTilt, at: time) {
        case .triggered:
            ForkLog.info("MuteTriggers: headTilt held \(Self.degrees(detector.deviation))° from baseline")
            onTrigger()
        case .nearMiss(let heldFor):
            ForkLog.info("MuteTriggers: headTilt near miss, held \(String(format: "%.2f", heldFor)) s")
        case nil:
            break
        }

        samplesSinceReport += 1
        guard let lastReportTime else {
            lastReportTime = time
            return
        }
        if time - lastReportTime >= Self.reportInterval {
            let rate = Double(samplesSinceReport) / (time - lastReportTime)
            ForkLog.info(
                "MuteTriggers: headTilt \(Int(rate.rounded())) samples/s, "
                    + "gravity tilt x \(Self.degrees(Self.tiltAngle(gravity.x)))° "
                    + "y \(Self.degrees(Self.tiltAngle(gravity.y)))° "
                    + "z \(Self.degrees(Self.tiltAngle(gravity.z)))°, "
                    + "baseline \(Self.degrees(detector.baseline))°, from baseline \(Self.degrees(detector.deviation))°",
            )
            samplesSinceReport = 0
            self.lastReportTime = time
        }
    }

    /// Angle from level for one component of the unit gravity vector.
    private static func tiltAngle(_ component: Double) -> Double {
        asin(min(1, max(-1, component)))
    }

    private static func degrees(_ radians: Double) -> Int {
        Int((radians * 180 / .pi).rounded())
    }

    private static func describe(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "allowed"
        @unknown default: return "unknown"
        }
    }
}

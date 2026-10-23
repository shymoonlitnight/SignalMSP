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
/// Angles are measured from a baseline that slowly follows the head while it's
/// upright, so posture changes (or leaning on a bike) don't count as a tilt.
struct HeadTiltDetector {
    enum Event: Equatable {
        /// A tilt was held long enough; toggle mute.
        case triggered
        /// A tilt ended before it was held long enough (logged for tuning).
        case nearMiss(heldFor: TimeInterval)
    }

    /// How far from the baseline counts as tilted, in radians (~34°).
    var threshold: Double = 0.6
    /// The head must come back within this (~14°) before the next trigger.
    var rearmThreshold: Double = 0.25
    /// How long the tilt must be held.
    var holdDuration: TimeInterval = 0.5
    /// How quickly the baseline follows the head while upright.
    var baselineTimeConstant: TimeInterval = 2.0

    private(set) var baseline: Double?
    private var lastTime: TimeInterval?
    private var tiltStart: TimeInterval?
    private var isArmed = true

    /// Distance of the last sample from the baseline, in radians.
    private(set) var deviation: Double = 0

    mutating func process(roll: Double, at time: TimeInterval) -> Event? {
        guard let baseline, let lastTime else {
            self.baseline = roll
            self.lastTime = time
            return nil
        }
        let elapsed = max(0, time - lastTime)
        self.lastTime = time
        deviation = abs(roll - baseline)

        // After a trigger, wait for the head to come back. The baseline stays
        // put meanwhile, so holding the tilt can't trigger again.
        if !isArmed {
            if deviation < rearmThreshold {
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
        self.baseline = baseline + (roll - baseline) * min(1, elapsed / baselineTimeConstant)
        return event
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
    private static let reportInterval: TimeInterval = 2
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
        let attitude = motion.attitude
        let time = motion.timestamp

        switch detector.process(roll: attitude.roll, at: time) {
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
                    + "roll \(Self.degrees(attitude.roll))° pitch \(Self.degrees(attitude.pitch))° "
                    + "yaw \(Self.degrees(attitude.yaw))°, tilt \(Self.degrees(detector.deviation))°",
            )
            samplesSinceReport = 0
            self.lastReportTime = time
        }
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

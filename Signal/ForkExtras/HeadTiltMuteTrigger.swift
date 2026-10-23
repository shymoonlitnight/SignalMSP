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
        /// A head movement past `reportThreshold` ended. `peak` is its largest
        /// signed distance from the baseline (positive = right), and `heldFor`
        /// how long it stayed past the trigger angle; logged for tuning.
        case movement(peak: Double, heldFor: TimeInterval, triggered: Bool)
    }

    /// How far from the baseline counts as tilted, in radians (~20°), per
    /// side. In testing, deliberate tilts peaked at 27–31° on both sides once
    /// the ear-to-ear axis was corrected, and looking down moved the sideways
    /// angle by only a few degrees.
    var rightThreshold: Double = 0.35
    var leftThreshold: Double = 0.35
    /// Head movements past this (~11°) are reported with their peak.
    var reportThreshold: Double = 0.2
    /// After a trigger, the head must come back within this (~14°) of the
    /// baseline, or of true upright, before the next trigger.
    var rearmThreshold: Double = 0.25
    /// How long the tilt must be held.
    var holdDuration: TimeInterval = 0.5
    /// How quickly the baseline follows the resting posture.
    var baselineTimeConstant: TimeInterval = 3.0
    /// Within this (~10°) of the baseline, it follows at the normal speed.
    /// Further out it follows only slowly, so the start of a deliberate tilt
    /// doesn't drag it along, but a baseline that's off still recovers.
    var followThreshold: Double = 0.17
    var slowBaselineTimeConstant: TimeInterval = 10.0
    /// The baseline stays within this (~15°) of true upright.
    var maxBaselineOffset: Double = 0.26
    /// A pause in samples longer than this (an AirPod taken out, updates
    /// paused) starts over, so a tilt from before it can't count as held.
    var maxSampleGap: TimeInterval = 0.5

    private(set) var baseline: Double = 0
    private var lastTime: TimeInterval?
    private var tiltStart: TimeInterval?
    /// Starts disarmed, so a head that's already tilted when the call starts
    /// (e.g. lying on one side) doesn't toggle mute. It arms once the head is
    /// near the baseline or upright.
    private var isArmed = false
    private var movementPeak: Double?
    private var movementHeld: TimeInterval = 0
    private var movementTriggered = false

    /// Signed distance of the last sample from the baseline (positive = right).
    private(set) var offset: Double = 0

    mutating func process(angle: Double, at time: TimeInterval) -> [Event] {
        if let lastTime, time - lastTime > maxSampleGap {
            self = HeadTiltDetector(copyingSettingsFrom: self)
        }
        guard let lastTime else {
            lastTime = time
            baseline = clampedBaseline(angle)
            offset = angle - baseline
            return []
        }
        let elapsed = max(0, time - lastTime)
        self.lastTime = time
        offset = angle - baseline
        let deviation = abs(offset)
        let isTilted = offset >= rightThreshold || offset <= -leftThreshold
        var events: [Event] = []

        // A tilt that ended before the hold time counts toward the movement.
        if !isTilted, let tiltStart {
            movementHeld += time - tiltStart
            self.tiltStart = nil
        }

        if deviation >= reportThreshold {
            if abs(offset) > abs(movementPeak ?? 0) {
                movementPeak = offset
            }
        } else if let movementPeak {
            events.append(.movement(peak: movementPeak, heldFor: movementHeld, triggered: movementTriggered))
            self.movementPeak = nil
            movementHeld = 0
            movementTriggered = false
        }

        // After a trigger, wait for the head to come back. The baseline stays
        // put meanwhile, so holding the tilt can't trigger again. A tilt
        // that's still past the trigger angle never re-arms, even if it's
        // near true upright (a tilt toward upright from a leaning baseline).
        if !isArmed {
            if !isTilted, deviation < rearmThreshold || abs(angle) < rearmThreshold {
                isArmed = true
            }
            return events
        }

        if isTilted {
            guard let tiltStart else {
                tiltStart = time
                return events
            }
            if time - tiltStart >= holdDuration {
                self.tiltStart = nil
                isArmed = false
                movementHeld += time - tiltStart
                movementTriggered = true
                events.append(.triggered)
            }
            return events
        }

        let timeConstant = deviation < followThreshold ? baselineTimeConstant : slowBaselineTimeConstant
        baseline = clampedBaseline(baseline + (angle - baseline) * min(1, elapsed / timeConstant))
        return events
    }

    init() {}

    /// A fresh detector (disarmed, no baseline) with the same settings.
    private init(copyingSettingsFrom other: HeadTiltDetector) {
        rightThreshold = other.rightThreshold
        leftThreshold = other.leftThreshold
        reportThreshold = other.reportThreshold
        rearmThreshold = other.rearmThreshold
        holdDuration = other.holdDuration
        baselineTimeConstant = other.baselineTimeConstant
        followThreshold = other.followThreshold
        slowBaselineTimeConstant = other.slowBaselineTimeConstant
        maxBaselineOffset = other.maxBaselineOffset
        maxSampleGap = other.maxSampleGap
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

    // Periodic summary, to check updates keep arriving while backgrounded or
    // locked. Lower this (e.g. to 1 s) when tuning the gesture.
    private static let reportInterval: TimeInterval = 60
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
        let sidewaysTilt = Self.tiltAngle(Self.earToEarComponent(of: gravity))

        for event in detector.process(angle: sidewaysTilt, at: time) {
            switch event {
            case .triggered:
                ForkLog.info("MuteTriggers: headTilt held \(Self.describeSide(detector.offset))")
                onTrigger()
            case .movement(let peak, let heldFor, let triggered):
                ForkLog.info(
                    "MuteTriggers: headTilt movement peaked \(Self.describeSide(peak)), "
                        + "held \(String(format: "%.1f", heldFor)) s\(triggered ? ", triggered" : "")",
                )
            }
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
                    + "z \(Self.degrees(Self.tiltAngle(gravity.z)))°, sideways \(Self.degrees(sidewaysTilt))°, "
                    + "baseline \(Self.degrees(detector.baseline))°, from baseline \(Self.describeSide(detector.offset))",
            )
            samplesSinceReport = 0
            self.lastReportTime = time
        }
    }

    /// The headphones' x axis isn't quite ear-to-ear: in testing (AirPods),
    /// looking down 38° moved x by -14°, so x is rotated ~21° toward the
    /// forward (y) axis. Mixing in that much of y cancels nods out of the
    /// sideways reading. This was measured on one person's AirPods; adjust
    /// if nods show up in the "sideways" log value.
    private static let earToEarAxisCorrection: Double = 21 * .pi / 180

    private static func earToEarComponent(of gravity: CMAcceleration) -> Double {
        gravity.x * cos(earToEarAxisCorrection) + gravity.y * sin(earToEarAxisCorrection)
    }

    /// Angle from level for one component of the unit gravity vector.
    private static func tiltAngle(_ component: Double) -> Double {
        asin(min(1, max(-1, component)))
    }

    private static func describeSide(_ offset: Double) -> String {
        "\(Self.degrees(abs(offset)))° \(offset >= 0 ? "right" : "left")"
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

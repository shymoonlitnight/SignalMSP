//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
private protocol CallShortcutIntent: AppIntent {}

@available(iOS 16.0, *)
extension CallShortcutIntent {
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { true }
}

@available(iOS 16.0, *)
struct ToggleMicrophoneMuteIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Toggle Microphone Mute"
    static var description = IntentDescription("Toggle microphone mute for the current call.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let isMuted = try await CallMuteController.live().toggle()
        return .result(value: isMuted)
    }
}

@available(iOS 16.0, *)
struct SetMicrophoneMuteIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Set Microphone Mute"
    static var description = IntentDescription("Set microphone mute for the current call.")

    @Parameter(title: "Muted")
    var isMuted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set microphone mute to \(\.$isMuted)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let updatedMuteState = try await CallMuteController.live().setMuted(isMuted)
        return .result(value: updatedMuteState)
    }
}

@available(iOS 16.0, *)
struct GetMicrophoneMuteStateIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Get Microphone Mute State"
    static var description = IntentDescription("Get microphone mute state for the current call.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let isMuted = try await CallMuteController.live().isMuted()
        return .result(value: isMuted)
    }
}

@available(iOS 16.0, *)
struct GetActiveCallStateIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Get Active Call State"
    static var description = IntentDescription("Get whether there is an active call.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let hasActiveCall = await CallMuteController.live().hasActiveCall
        return .result(value: hasActiveCall)
    }
}

@available(iOS 16.0, *)
struct CallMuteShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMicrophoneMuteIntent(),
            phrases: [
                "Toggle microphone mute in \(.applicationName)",
                "Toggle mute in \(.applicationName)",
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: SetMicrophoneMuteIntent(),
            phrases: [
                "Set microphone mute in \(.applicationName)",
                "Set mute in \(.applicationName)",
            ],
            shortTitle: "Set Mute",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: GetMicrophoneMuteStateIntent(),
            phrases: [
                "Get microphone mute state in \(.applicationName)",
                "Get mute state in \(.applicationName)",
            ],
            shortTitle: "Get Mute State",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: GetActiveCallStateIntent(),
            phrases: [
                "Get active call state in \(.applicationName)",
                "Get active call in \(.applicationName)",
            ],
            shortTitle: "Get Active Call",
            systemImageName: "phone"
        )
    }
}

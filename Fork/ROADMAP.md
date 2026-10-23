# SignalMSP roadmap

Planned work for hands-free call mute/unmute. Build and branch setup is in
[README.md](README.md).

**Main constraint:** keep anything that could go upstream cleanly separated
from fork-only experiments and personal config.

## Branch restructure

Target layout (stacked; each branch builds on the one to its left):

```
upstream/main  →  app-intents  →  mute-triggers  →  personal
 (Signal)         (upstreamable)   (fork-only)       (personal build)
```

| Branch | Contents | Rules |
|---|---|---|
| `app-intents` | App Intent, shared mute toggle, Control Center control, call-screen key commands | Small, tidy, always PR-ready. No personal config, experiments, or notes. |
| `mute-triggers` | Trigger-source infrastructure, play/pause, volume double-tap, AirPods head gesture, and their settings | Fork-only; never sent upstream. |
| `personal` | Signing/team/bundle ID, icon, entitlements, TestFlight config, build script, these docs | Top of stack; what gets built. |

To do:
- [ ] Create `app-intents` from the current `main` intent commit. Keep `main`
      tracking upstream, or retire it.
- [x] Split the unrelated `RegistrationIdMismatchManager` change out of the
      App Intents commit into its own commit. Keep it out of `app-intents`
      (separate PR branch if it goes upstream).
- [x] Move `CallMuteShortcutsTest` into its own file
      (`Signal/test/Calls/CallMuteShortcutsTest.swift`).
- [ ] Create `mute-triggers` on top of `app-intents`; rebase `personal` onto it.
- [ ] Turn on `rebase.updateRefs` and `rerere.enabled`. Update the build
      script to do one `git rebase --update-refs upstream/main` instead of
      per-branch rebases.
- [ ] Keep fork-only code in its own folder (e.g. `Signal/ForkExtras/`) to
      minimize upstream conflicts. Group new pbxproj entries and keep them few.
- [ ] Optional: a `FORK_EXPERIMENTS` compile flag around `mute-triggers`
      code, so `personal` can also build an upstream-only flavor.
- [ ] Commit the build script (signing, TestFlight upload) to `personal`.

## Personal build polish

- [x] Wire up `SIGNAL_APP_NAME` (`CFBundleDisplayName` in `Signal-Info.plist`).
- [ ] Add `Config/User.xcconfig.sample` entries for the new settings, or a
      separate personal sample file.
- [ ] TestFlight config and upload.

## `app-intents` (upstreamable)

1. **App Intents / Shortcuts.** ✅ Done (`CallMuteShortcuts.swift`). Through
   Shortcuts this already covers:
   - Full Keyboard Access → Commands → Shortcuts (a key on a Bluetooth keyboard
     or a page-turner pedal in keyboard mode).
   - AssistiveTouch (extra mouse buttons) and Switch Control (adaptive
     switches such as the AbleNet Blue2).
2. **Shared toggle.** Confirm or extract a single entry point (e.g.
   `CallMuteController.toggle()`) that every trigger calls. It owns the mute
   state plus feedback (earcon/haptic). Today the logic is
   `setMicrophoneMuteState` in `CallMuteShortcuts.swift`.
3. **Control Center control** (iOS 18+, `SetValueIntent` toggle). Thin layer
   over the intent with a big, glove-friendly tap target. Can also be assigned
   to the Action Button or Lock Screen.
4. **Call-screen hardware key commands.** `UIKeyCommand` / `pressesBegan`
   for arrows, Page Up/Down, and Space from keyboards and keyboard-mode page
   turners. Only works with Signal in the foreground and the phone unlocked.

## `mute-triggers` (fork-only)

These need extra permissions, take over system controls, or might interfere
with CallKit, so upstream is unlikely to accept them.

- **Infrastructure.** `MuteTriggerSource` protocol with `start()` / `stop()`.
  Sources start on call connect and stop on call end. Each has its own
  setting (default off). Toggles are debounced so two sources firing
  together don't double-toggle. Use one hook at call start/end, not edits
  spread across Signal files.
- **Volume double-tap.** Observe `AVAudioSession.outputVolume` (KVO) during a
  call. A quick double press (e.g. "−" twice, or "−" then "+", within about
  400 ms) toggles mute, then restores the previous volume (may need the
  `MPVolumeView` slider trick). Should work backgrounded or locked, because the
  call's audio session is active. Most reliable option for the BT13 remote.
- **Play/pause remote command.** `MPRemoteCommandCenter.togglePlayPauseCommand`
  during a call. Target hardware: **BT13 handlebar media remote** (+,
  play/pause, −), which sends media keys, not keyboard keys.
  ⚠️ CallKit may intercept play/pause and **end the call**, so test this first.
- **AirPods head gesture.** `CMHeadphoneMotionManager` (AirPods Pro, Max,
  3rd/4th gen). Apple's built-in nod/shake isn't exposed as an API.
  - Avoid nod and shake, since people do both constantly in conversation. Use a
    sideways tilt (roll) held about 0.5 s, or a double tilt.
  - Needs `NSMotionUsageDescription` in Info.plist.
  - Check that updates keep arriving while backgrounded or locked during a call.

## Other ideas

- **Live Activity** with a mute button (Lock Screen / Dynamic Island).

## Suggested order

1. On `app-intents`: confirm or extract the shared toggle, then add the
   Control Center control and call-screen key commands.
2. Create `mute-triggers`: add the trigger infrastructure, then volume
   double-tap, then play/pause, then head gesture.
3. Rebase `personal` onto `mute-triggers` and update the build script.

## Test plan

For each trigger, test with the call screen in the foreground, with Signal
in the background, and with the phone locked. Also check that:

- [ ] BT13 play/pause does not end the call.
- [ ] Normal conversation (nodding, talking) doesn't trigger the head gesture.
- [ ] Double-pressing volume leaves the volume where it started.
- [ ] Triggers don't fire when no call is active.
- [ ] `app-intents` builds on its own, with no dependency on higher layers.

# SignalMSP implementation plan

How [ROADMAP.md](ROADMAP.md) gets built, in checkpoints. Each checkpoint ends
with a **Verify** step; tick it off only after that check passes.

Decisions (2026-10-23):
- `main` is retired; `app-intents` replaces it.
- The Control Center control stays in `app-intents` for now; revisit after CP1.3a.
- The `RegistrationIdMismatchManager` fix lives on its own PR branch
  `regid-warnings` and is carried as the first commit of `mute-triggers`.

Known risks:
- Signal has no widget extension. A Control Center control needs one (new
  target, bundle ID, App Group, profile), so CP1.3a is a go/no-go test.
- During a CallKit call, iOS usually routes headset play/pause to CallKit
  (end/hold call), so CP2.0 tests this before any play/pause work.

## Phase 0: Branch restructure

- [x] **CP0.1 Create the stack.** `app-intents` = `upstream/main` + the intent
  commit. `regid-warnings` = `upstream/main` + the registration ID fix.
  `mute-triggers` = `app-intents` + the registration ID fix. `personal` rebased
  onto `mute-triggers`. `main` retired (locally first; on GitHub after the
  default branch is switched).
  **Verify:** `git log --oneline --graph upstream/main..personal` shows
  `app-intents` → `mute-triggers` → `personal`;
  `git log --oneline upstream/main..app-intents` shows one commit.
- [x] **CP0.2 `release.py` knows the stack.** Replace the hard-coded `main`
  left-behind check with the branches from `stack_branches()`; update the self-test.
  **Verify:** `Fork/release.py self-test` passes;
  `Fork/release.py --no-clean --no-archive --no-upload` rebases all branches.
- [x] **CP0.3 Sample config.** Add the `SIGNAL_*` settings, commented out, to
  `Config/User.xcconfig.sample` (on `personal`).
  **Verify:** a fresh copy builds with upstream defaults; filled in, it signs with your team.
- [x] **CP0.4 `app-intents` builds alone.**
  **Verify:** on `app-intents`,
  `xcodebuild -workspace Signal.xcworkspace -scheme Signal -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
  succeeds. Repeat after every later phase.

## Phase 1: `app-intents` (upstreamable)

- [x] **CP1.1 Shared toggle.** Move the mute logic out of
  `CallMuteShortcuts.swift` into `Signal/Calls/CallMuteController.swift`
  (`toggle()`, `setMuted(_:)`, `isMuted`, haptic feedback). Intents become thin wrappers.
  **Verify:** `CallMuteShortcutsTest` and new `CallMuteControllerTest` pass. On
  device, the Toggle shortcut works with the call screen open, backgrounded,
  and locked; call-screen mute button and CallKit stay in sync.
- [x] **CP1.2 Call-screen key commands.** `keyCommands` (Space, arrows,
  Page Up/Down) on the individual and group call view controllers, calling
  `CallMuteController.toggle()`.
  **Verify:** simulator with hardware keyboard: Space toggles mute. Device:
  page-turner pedal toggles mute. Typing elsewhere is unaffected.
- [ ] **CP1.3a Control Center test (go/no-go).** Minimal widget extension with a
  `ControlWidgetToggle` that runs the intent in the app process.
  **Verify:** iOS 18 device: control appears and mutes during a call. If messy,
  move the control to `mute-triggers`.
- [ ] **CP1.3b Control Center control.** Shared mute state via App Group
  defaults; `ControlCenter.shared.reloadControls` on every mute change.
  **Verify:** control state always matches the call screen (including muting
  from the call UI); works from Lock Screen and Action Button; errors with no call.
- [ ] **CP1.4 PR-ready.**
  **Verify:** CP0.4 passes; diff has no personal config or notes; tests pass.

## Phase 2: `mute-triggers` (fork-only)

- [ ] **CP2.0 Play/pause test (~30 min).** Throwaway `MPRemoteCommandCenter`
  handler; press BT13 play/pause during a call.
  **Verify:** record whether the call ends, holds, or the handler fires. Decides CP2.3.
- [ ] **CP2.1 Trigger infrastructure.** `Signal/ForkExtras/`: `MuteTriggerSource`
  (`start()`/`stop()`), `MuteTriggerCoordinator` driven by
  `CallServiceStateObserver` (one registration line in Signal code), ~300 ms
  debounce, per-source setting (default off) in a small settings screen.
  Optional `FORK_EXPERIMENTS` flag.
  **Verify:** unit tests for debounce and start/stop; device logs show sources
  start/stop with calls and nothing runs without a call.
- [ ] **CP2.2 Volume double-tap.** KVO on `outputVolume`, double press within
  ~400 ms toggles mute, volume restored via `MPVolumeView`.
  **Verify:** works foreground/background/locked; volume ends where it started;
  single presses still change volume.
- [ ] **CP2.3 Play/pause** (only if CP2.0 passed).
  **Verify:** BT13 toggles mute and never ends the call, in all three states.
- [ ] **CP2.4 AirPods head gesture.** `CMHeadphoneMotionManager`, sideways tilt
  held ~0.5 s or double tilt; `NSMotionUsageDescription`.
  **Verify:** works backgrounded/locked; 5 minutes of normal conversation
  (nodding, turning) gives no false triggers.

## Phase 3: Integration

- [ ] **CP3.1 Full stack on TestFlight.** Rebase `personal`, run
  `Fork/release.py`, install from TestFlight.
  **Verify:** ROADMAP test plan for every trigger in all three states; tick
  off ROADMAP.md; update README.md.

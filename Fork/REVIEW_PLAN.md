# SignalMSP review and remediation plan

Reviewed: branch `personal` at `a7efbf4` (2026-11-09). Upstream base: `32b101a`
(Signal-iOS `main`, 2026-11-05).

Scope: the fork's own 16 commits (43 files, about 3,700 added lines). Upstream
Signal code was read only where the fork hooks into it; it was not audited.

How this review was done, and its limits:

- Static reading only. The review machine was Linux with no Xcode, so **no
  Swift was compiled and no test was run**. `Fork/release.py self-test` was
  also not run (blocked by the review sandbox). Stage 0 below establishes the
  real baseline before anything is changed.
- Line numbers refer to `a7efbf4`. If the branch has been rebased since, find
  the code by the quoted symbol name, not the line number.

---

## Part 1: Findings

Severity: **High** = can hurt the user in normal use. **Medium** = real defect
or data-loss path that needs an unusual but plausible situation. **Low** =
hardening, cleanup, or edge case.

### Security and privacy

| ID | Sev | Finding | Where |
|---|---|---|---|
| S1 | High | **Hands-free unmute has no feedback the user can perceive.** The only feedback is a haptic on the phone (`ImpactHapticFeedback`), which does not fire when the app is backgrounded or the phone is locked, and cannot be felt with the phone in a pocket. Head tilt and track skip both *toggle*, so a false positive or a double trigger can open the microphone without the user knowing. This is the main privacy risk of the fork. | `Signal/Calls/CallMuteController.swift:77-79`, `Signal/ForkExtras/MuteTriggers.swift:105-121` |
| S2 | Medium | **`release.py` can overwrite commits on GitHub.** `update()` runs `git fetch origin` and then `git push --force-with-lease origin <branches>`. Because the fetch has just refreshed the remote-tracking refs, the lease always passes. Commits that exist only on `origin` (pushed from another machine, or edited on github.com) are destroyed silently. `left_behind_branches()` only inspects local branches. | `Fork/release.py:509-551` |
| S3 | Medium | **`--no-archive` uploads "the newest archive" without checking what it is.** It picks by file modification time and scheme name only. It does not check the bundle ID, or that the archive was built from the current commit. With `--yes` this is unattended. | `Fork/release.py:626-640` |
| S4 | Low | The App Intents and the Control Center toggle run from the Lock Screen with no authentication, so anyone holding the locked phone during a call can unmute it, and "Get Active Call State" reveals whether a call is active. This matches what CallKit's own lock-screen call UI allows, and requiring Face ID would defeat the gloves use case. **Recommendation: accept and document**, no code change. | `Signal/Shortcuts/CallMuteShortcuts.swift`, `SignalControls/CallMuteControlIntent.swift` |
| S5 | Low | Every head movement past 11° is written to Signal's debug log and, with `privacy: .public`, to the system log. Signal debug logs are sometimes submitted to Signal support; these lines add fork-only noise and a record of head movement. | `Signal/ForkExtras/HeadTiltMuteTrigger.swift:211-216`, `ForkLog.swift` |
| S6 | Low | `check_stray_files()` lists untracked files but not git-ignored ones. Ignored files inside a synchronized Xcode folder are still bundled into the app. | `Fork/release.py:188-202` |
| S7 | Low | `run()` logs the whole `altool` command line, including the API key ID, issuer ID and key file path. These are identifiers, not the secret, but they end up in terminal scrollback and any log capture. | `Fork/release.py:88-94, 659-660` |

No secrets, team IDs or personal bundle IDs were found committed.
`Config/User*.xcconfig` is git-ignored, and commit authorship uses a GitHub
no-reply address.

### Bugs

| ID | Sev | Finding | Where |
|---|---|---|---|
| B1 | Medium | After the `await` in `setMuted(_:on:)`, the controller reports to CallKit and plays feedback without re-checking that the call is still the current call and has not ended. If the call ends during the wait, it sends a `CXSetMutedCallAction` for a dead call; in the simulator, `SimulatorCallUIAdaptee.setIsMuted` hits an `owsPrecondition` and crashes. | `Signal/Calls/CallMuteController.swift:125-135` |
| B2 | Medium | **Three separate debounces and no shared controller.** `CallMuteController.live()` builds a new controller on every call. Key commands keep their own static timestamp, the trigger coordinator keeps another, and Shortcuts and Control Center have none. A key press and a head tilt 100 ms apart both go through and cancel each other out. | `CallMuteController.swift:66`, `CallMuteKeyCommands.swift:44-71`, `MuteTriggers.swift:40, 104-110` |
| B3 | Medium | Trigger sources start as soon as *any* call object exists, including an incoming call that is still ringing and a group-call lobby. The Motion & Fitness permission prompt can therefore appear while the phone is ringing, and Now Playing is claimed before the call connects. `ROADMAP.md` says sources "start on call connect". | `MuteTriggers.swift:66-72` |
| B4 | Low | Track skip claims Now Playing only if `nowPlayingInfo == nil` at call start. If a voice message was playing, it does not claim; when the audio player then tears down it sets `nowPlayingInfo = nil` (`SignalUI/AV/AudioPlayer.swift:389`), leaving nothing claimed, so the trigger is silently dead for that call. `stop()` also disables the next/previous commands unconditionally. | `TrackSkipMuteTrigger.swift:36-58` |
| B5 | Low | The call view controller stays first responder after the call is minimized to picture-in-picture. Not confirmed, but Space or arrow keys pressed while browsing chats may toggle mute. The existing verification only covered "typing elsewhere". | `GroupCallViewController.swift:647-663`, `IndividualCallViewController.swift:254-272` |
| B6 | Low | The Control Center toggle shows "Unmuted" when there is no call, and stays "Muted" if the app is killed mid-call (documented in a code comment). | `SignalControls/CallMuteControl.swift`, `CallMuteControlState.swift` |
| B7 | Low | `asc_next_build_number()` reads one page of 200 builds with no sort; beyond 200 builds of one version the number is wrong. | `Fork/release.py:359-365` |
| B8 | Low | The JWT signature parser validates with `assert`, which `python -O` removes. | `Fork/release.py:310-312` |
| B9 | Low | `xcconfig()` ignores keys containing digits, conditional settings (`KEY[sdk=...]`), `#include`, and `$(OTHER)` references; a value containing `//` is cut off. `personal_setting()` duplicates the parsing loop. | `Fork/release.py:123-149` |
| B10 | Low | `testflight_notes()` picks the "previous" tag as the newest other tag by date. Regenerating notes for an older build picks a newer tag and silently drops the upstream section. | `Fork/release.py:449-450` |
| B11 | Low | Declining the Xcode version prompt returns exit code 0, as if the release succeeded. | `Fork/release.py:565-567` |

### Performance

Nothing here is user-visible today. All are Low.

| ID | Finding | Where |
|---|---|---|
| P1 | Headphone motion is delivered to the main queue at sensor rate for the whole call (and from ringing, see B3). The work per sample is small, but it is main-thread work during a call and keeps the AirPods motion sensor on longer than needed. | `HeadTiltMuteTrigger.swift:177-182` |
| P2 | `CallMuteControlState.defaults` opens the App Group `UserDefaults` suite on every read and write. | `SignalControls/CallMuteControlState.swift:17-22` |
| P3 | `asc_request()` signs a new JWT (one `openssl` process) for every API request, including each poll while waiting for a build. | `Fork/release.py:322-326` |

### Architecture and process

| ID | Sev | Finding |
|---|---|---|
| A1 | Medium | **Nothing runs automatically on the fork.** Upstream's workflows trigger only on pull requests and pushes to `main` / `release/*`. Pushes to `personal` and the stack run no build, no Swift tests and no `release.py self-test`. Every check in `PLAN.md` is manual. |
| A2 | Medium | **Test gaps on the code that actually touches a call.** `SignalCallMuteTarget` (the only production implementation of `CallMuteTarget`), `TrackSkipMuteTrigger`, `SetCallMuteControlIntent` and the real observer paths of `CallMuteControlUpdater` have no tests. `CallMuteShortcutsTest` checks two static flags. `release.py`'s App Store Connect functions have no tests because there is no fake for the API. |
| A3 | Low | "User chose a mute state" is stored twice: `CallControlsViewModel.didOverrideDefaultMuteState` (upstream) and the new `GroupCall.didOverrideDefaultMuteState`. Both must be kept in step by hand, and the edit to `CallControls.swift` is rebase-conflict surface. Acceptable; documented here so it is not rediscovered as a bug. |
| A4 | Low | User-facing strings in the intents, errors and control are hard-coded English. Irrelevant for a personal build, but a blocker if `app-intents` is offered upstream. |
| A5 | Low | Docs drift: `Fork/README.md` says the folder exists "only on `mute-triggers` and above" (it is on `personal`); `ROADMAP.md` and `PLAN.md` describe behavior the code does not have (B3, earcon). `SignalControls/Info.plist` hard-codes version `8.37` and is only corrected during a `release.py` archive. |

What is in good shape: `HeadTiltDetector` is a pure value type with 11
focused tests; `CallMuteController` is injectable and well tested against a
fake; `release.py` uses no shell strings, verifies TLS by default, keeps the
API key out of the repo and restores the plists in a `finally`.

---

## Part 2: Rules for whoever executes this plan

Read this whole part before starting. It applies to every step.

1. **Work on one new branch.** Create `review-fixes` from `personal`. Make one
   commit per step. Start each commit subject with the layer it belongs to, in
   square brackets, exactly as given in the step: `[app-intents]`,
   `[mute-triggers]` or `[personal]`.
2. **Do not rewrite history and do not push.** No `git rebase`, no
   `git push --force`, no `git commit --amend` on existing commits, no pushing
   of any branch. The owner moves the commits into the stacked branches
   afterwards (Stage 8).
3. **Do not run `Fork/release.py` without a subcommand, and never with
   `--yes`.** The only invocations allowed are `Fork/release.py self-test` and
   `Fork/release.py notes ... --show`.
4. **Only edit the files named in the step.** If a step seems to need another
   upstream file, stop and report.
5. **Do the stages in order.** Inside a stage, do the steps in order.
6. **A step is done only when its Verify block passes.** If a Verify command
   fails and the cause is not obvious within two attempts, stop, leave the
   work uncommitted, and report the command and its full output.
7. **Never weaken a test to make it pass**, and never delete an existing test.
8. Python steps (Stages 1 and 2) run on any OS with Python 3.10+, git and
   openssl. Swift steps (Stages 3 to 7) need macOS with the Xcode version in
   `.xcode-version`.
9. Steps marked **DEVICE** cannot be verified by an automated agent. Implement
   the code, run the automated Verify, and list the DEVICE check in the final
   report for the owner. Do not mark it as verified.

### Standard Swift test command

Referred to below as `SWIFT_TEST <TestClass> [<TestClass> ...]`.

```bash
xcrun simctl list devices available | grep -m1 iPhone
```

Take the device name from that output and use it as `<SIM>`:

```bash
xcodebuild test -workspace Signal.xcworkspace -scheme Signal -destination 'platform=iOS Simulator,name=<SIM>' CODE_SIGNING_ALLOWED=NO -only-testing:SignalTests/<TestClass>
```

Add one `-only-testing:SignalTests/<TestClass>` per class. Pass means the
output ends with `** TEST SUCCEEDED **`. The first build takes 20 to 40
minutes.

---

## Part 3: The plan

### Stage 0: Baseline (no code changes)

**0.1 Create the branch.**

```bash
git checkout personal
```

```bash
git checkout -b review-fixes
```

Verify: `git status` shows a clean tree on `review-fixes`.

**0.2 Record the Python baseline.**

```bash
Fork/release.py self-test
```

Verify: the last line is `self-test ok`. If it is not, stop and report; the
later Python steps assume a passing start.

**0.3 Record the Swift baseline** (macOS only).

`SWIFT_TEST CallMuteControllerTest CallMuteKeyCommandsTest CallMuteControlUpdaterTest CallMuteShortcutsTest HeadTiltDetectorTest MuteTriggerCoordinatorTest`

Verify: `** TEST SUCCEEDED **`. Write down the number of tests executed; later
stages must never report fewer.

---

### Stage 1: `release.py` safety (fixes S2, S3, S6, S7, B7 to B11, P3)

All commits in this stage: prefix `[mute-triggers]`, file `Fork/release.py`
only. After **every** step in this stage run:

```bash
Fork/release.py self-test
```

and require `self-test ok`.

**1.1 Stop the force-push from destroying remote commits (S2).**

In `update()`:

- Immediately after the two `git fetch` calls, for each branch in
  `[*stack, branch]` (compute `stack` before this check), read
  `origin/<bb>` with `git_try(repo, 'rev-parse', f'origin/{bb}')`. If it
  exists and `is_ancestor(repo, f'origin/{bb}', bb)` is false, raise
  `Stop(f"origin/{bb} has commits that local '{bb}' doesn't", ...)` with a
  step telling the user to inspect `git log {bb}..origin/{bb}`.
- Save each branch's `origin/<bb>` SHA in a dict at that point.
- Change the push to pass one explicit lease per branch:
  `--force-with-lease=<bb>:<saved sha>`. For a branch with no remote ref, use
  `--force-with-lease=<bb>:` (empty expected value means "must not exist").

Test to add in `_test_update()`, after the existing assertions: clone
`origin` into a second working copy, commit on `personal` there, push it, then
call `update(repo, 'personal', yes=True)` in the first copy and assert it
raises `Stop` whose message contains `origin/personal has commits`. Then
assert `git(origin, 'rev-parse', 'personal')` still equals the second copy's
commit (nothing was overwritten).

Verify: self-test passes, and temporarily reverting only the new check makes
the new assertion fail (then restore the check).

**1.2 Check the archive before uploading it (S3).**

In `release()`, after `archive_path` is settled and before the upload
`confirm(...)`:

- Call `archive_info(archive_path)`.
- If `info['bundle_id'] != app_bundle_id(repo)`, raise `Stop`.
- If `info['commit']` is set and differs from `git(repo, 'rev-parse', 'HEAD')`
  (compare by prefix, because the archive stores a short or long SHA), then:
  when the archive was built in this run, raise `Stop`; when it came from
  `--no-archive`, include both SHAs in the confirm question and **ask even if
  `yes` is true** (call `confirm(..., yes=False)`).

Refactor the check into a function `check_archive(repo, archive_path,
built_now)` returning the mismatch text or `None`, so it can be tested without
xcodebuild. Add tests in `_test_archive_info()` for: matching archive, wrong
bundle ID, different commit.

Verify: self-test passes with the three new assertions.

**1.3 Include ignored files in the stray-file check (S6).**

In `check_stray_files()`, add `--ignored=matching` to the `git status` call
and treat lines starting with `!! ` the same as `?? `. Skip `.DS_Store`.
Extend the existing stray-file test: write a `.gitignore` containing
`Kit/build/`, create `Kit/build/x`, and assert `Stop` is raised.

**1.4 Redact identifiers in the command log (S7).**

Give `run()` a keyword argument `redact=()`: a tuple of argument values to
print as `***`. Pass the key ID, issuer ID and key path from the `altool`
call and from `asc_auth_args()` users. Add a small test that captures
`sys.stderr` around a `run('true', 'SECRETVALUE', redact=('SECRETVALUE',))`
call and asserts the value is absent.

**1.5 Small correctness fixes (B7, B8, B10, B11, P3).** One commit.

- B7: in `asc_next_build_number()`, request `sort='-version'` and `limit=1`
  is not safe (the API sorts build numbers as strings). Instead follow
  `links.next` until absent: add `asc_get_all(endpoint, **params)` that
  loops, and use it here.
- B8: replace the `assert` in `der_int` with
  `if buf[pos] != 0x02: raise Stop('unexpected signature format from openssl')`.
- B10: in `testflight_notes()`, when `tag` is given, parse
  `<version>-<build>` from each tag into a tuple of ints and choose the
  highest tag that sorts *below* `tag`. Fall back to the current behavior
  when `tag` is `None` or a tag does not parse. Add a test: tags `8.33-4`,
  `8.34-1`, `8.34-2`; notes for `8.34-1` must say `since 8.33-4`.
- B11: in `release()`, change the `return` after the declined Xcode prompt to
  `raise Stop('cancelled')`.
- P3: cache the token in a module-level variable with its expiry; reuse it
  until 60 seconds before expiry. In `self_test()`, reset the cache in the
  `finally` block and at the top of `_test_asc_token`.

**1.6 xcconfig parsing (B9).** One commit.

- Make `xcconfig()` the only parser: add a parameter
  `names=('Project.xcconfig', 'User.xcconfig')` and have `personal_setting()`
  call `xcconfig(repo, names=('Project.xcconfig',))` instead of its own loop.
- Widen the key pattern to `[A-Za-z_][A-Za-z0-9_]*`. Skip lines whose key is
  followed by `[` (conditional settings) rather than misreading them.
- Only strip a trailing `// comment` when the `//` is preceded by whitespace
  or starts the value.
- After reading, expand `$(NAME)` and `${NAME}` references to other parsed
  keys, at most 5 passes; leave unknown references as written.
- In `personal_setting()`, if the final value still contains `$(`, raise
  `Stop(f'{key} = {value} could not be resolved')`.

Tests in `_test_repo()`: a `User.xcconfig` with
`SIGNAL_ORG_BUNDLEID_PREFIX = $(SIGNAL_BUNDLEID_PREFIX)` resolves to
`org.mine`; a value `https://example.com // note` keeps the URL; a key
`FOO2 = bar` is read.

**Stage 1 exit check:** `Fork/release.py self-test` prints `self-test ok`,
and `git diff personal --stat` lists only `Fork/release.py`.

---

### Stage 2: Automation (fixes A1)

**2.1 Add a fork workflow.** Prefix `[mute-triggers]`. New file
`.github/workflows/fork.yml` only. Do not edit upstream's workflow files.

Contents, in outline:

- `on: push` for branches `app-intents`, `build-config`, `mute-triggers`,
  `personal`, `review-fixes`; plus `workflow_dispatch`.
- Job `release-script` on `ubuntu-latest`: checkout, then
  `python3 Fork/release.py self-test`. (The PlistBuddy part of the self-test
  already skips itself off macOS.)
- Job `swift-tests` on `macos-latest`, **only** `if: github.event_name ==
  'workflow_dispatch'`: copy the Xcode selection and dependency steps from
  the `build_and_test` job in `.github/workflows/main.yml`, then run the
  Standard Swift test command for the six fork test classes from step 0.3.
  It is manual because a full Signal build takes most of an hour.
- `permissions: contents: read` at the top level. No secrets.

Verify:

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/fork.yml'))"
```

exits 0 (install PyYAML if missing). The real run can only be confirmed by the
owner after pushing: list "confirm the `fork` workflow goes green on GitHub"
in the final report.

---

### Stage 3: One mute controller (fixes B1, B2)

Prefix `[app-intents]`. Files: `Signal/Calls/CallMuteController.swift`,
`SignalTests/Calls/CallMuteControllerTest.swift`.

**3.1 Re-check the call after waiting (B1).**

Add `var isCurrent: Bool { get }` to `CallMuteTarget`. In
`SignalCallMuteTarget`, implement it as
`callService.callServiceState.currentCall === call`. In `setMuted(_:on:)`,
after the `waitForMuteState` guard, add:

```swift
guard call.isCurrent, !call.hasEnded else {
    throw CallMuteError.callEnded
}
```

Add `var isCurrent = true` to `FakeCall`. New test
`testCallEndingDuringWaitDoesNotReportOrGiveFeedback`: use
`.afterPolls(3)`, set `call.hasEnded = true` from a `Task` started just before
`toggle()`, and assert `.callEnded` is thrown and `reportedToSystem` and
`feedback` are empty.

**3.2 Shared instance with built-in debounce and serialization (B2).**

In `CallMuteController`:

- Add `static let shared: CallMuteController = .live()` and make `live()`
  `private`. (Tests keep using the designated initializer.)
- Add initializer parameters `debounceInterval: TimeInterval = 0.3` and
  `now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }`.
- Add `private var lastToggleTime: TimeInterval?` and
  `private var isChanging = false`.
- `toggle()` only (not `setMuted`): if a previous toggle started less than
  `debounceInterval` ago, or `isChanging` is true, do not change anything;
  return the current `isMuted` of the active call. Set `lastToggleTime` before
  the first `await`. Set `isChanging = true` around the body of
  `setMuted(_:on:)` with `defer { isChanging = false }`.
- `setMuted(_:)` stays un-debounced because it is idempotent.

Replace every `CallMuteController.live()` call site with
`CallMuteController.shared`:
`Signal/Shortcuts/CallMuteShortcuts.swift` (4 places),
`SignalControls/CallMuteControlIntent.swift` (1),
`Signal/Calls/UserInterface/CallMuteKeyCommands.swift` (1),
`Signal/ForkExtras/MuteTriggers.swift` (1, the default `toggleMute` argument).
Those last three files are on higher layers; commit their one-line changes
separately with prefix `[mute-triggers]`.

Tests to add: two `toggle()` calls 0.1 s apart (using an injected clock)
request mute once; two calls 0.3 s apart request twice; `setMuted(true)`
immediately after `toggle()` is not dropped.

**3.3 Remove the now-duplicate debounces.** Prefix `[mute-triggers]`.

- `CallMuteKeyCommands.swift`: delete `debounceInterval`, `lastToggleTime`,
  `shouldToggle`, and the guard in `toggleMute()`. Delete
  `testRepeatedPressesAreDebounced` from `CallMuteKeyCommandsTest` **in the
  same commit** and say so in the commit message (the behavior moved to
  `CallMuteControllerTest`; this is the one permitted test removal).
- `MuteTriggers.swift`: delete `debounceInterval`, `lastTriggerTime`, `now`
  and the debounce block in `trigger(from:)`. Update
  `MuteTriggerCoordinatorTest`: remove the `now:` argument and replace
  `testDebounceIgnoresTriggersCloseTogether` with a test that two triggers
  each call `toggleMute` once (the coordinator no longer filters).

Verify (after 3.3):
`SWIFT_TEST CallMuteControllerTest CallMuteKeyCommandsTest MuteTriggerCoordinatorTest CallMuteShortcutsTest`
succeeds, and

```bash
grep -rn "CallMuteController.live()" Signal SignalControls SignalTests
```

prints nothing.

---

### Stage 4: Audible feedback (fixes S1)

This is the highest-value change. Prefix `[app-intents]` for 4.1,
`[mute-triggers]` for 4.2.

**4.1 Play a distinct sound for mute and for unmute.**

Upstream already ships two suitable sounds and a way to play them inside a
call:

- `StandardSound.beginNextTrack` is `state-change_confirm-down.caf` and
  `StandardSound.endLastTrack` is `state-change_confirm-up.caf`
  (`SignalServiceKit/Util/Sounds.swift:107-108, 203-204`).
- `Sounds.audioPlayer(forSound: .standard(sound), audioBehavior: .call)`
  (`SignalUI/AV/Sounds+SignalUI.swift:20`) is how
  `Signal/Calls/CallAudioService.swift:433-445` plays in-call sounds.

In `CallMuteController.swift`, add a small `@MainActor final class
CallMuteEarcon` that holds one `AudioPlayer?` property, and has
`func play(isMuted: Bool)`: stop the previous player, build a new one with
`.beginNextTrack` when `isMuted` is true and `.endLastTrack` when false, keep
it in the property, and call `play()`. In `live()`, create one `CallMuteEarcon`
and call it from the `feedback` closure **in addition to** the existing
haptic. Do not route this through `CallAudioService` (that would stop a
ringback or join sound).

Automated verify: `SWIFT_TEST CallMuteControllerTest` still succeeds (the
tests inject their own `feedback`, so they are unaffected), and the app
builds.

**DEVICE check (owner):** in a one-to-one call with AirPods, phone locked:
trigger mute and unmute by Shortcut. Expected: a falling tone on mute and a
rising tone on unmute, heard in the AirPods, not sent to the other party, and
the call audio continues afterwards. If the tone is audible to the other
party, or interrupts call audio, revert this step and report.

**4.2 Optional, needs an owner decision: direction-specific head tilt.**
Do not implement unless the owner says so. Proposal: a third Settings switch
"Head Tilt: Left Mutes, Right Unmutes" that calls `setMuted(true/false)`
instead of `toggle()`. An idempotent command cannot be inverted by a false
positive or a double trigger, which is the remaining risk after 4.1.
`HeadTiltDetector.Event.triggered` would need to carry the side
(`detector.offset >= 0` is right).

---

### Stage 5: Trigger sources (fixes B3, B4, S5, P1)

Prefix `[mute-triggers]`. Files under `Signal/ForkExtras/` and
`SignalTests/ForkExtras/` only.

**5.1 Start sources when the call is connected, not when it appears (B3).**

`MuteTriggerCoordinator` currently treats any non-nil call as started. Change
it to follow the same observer pattern `CallMuteControlUpdater` already uses
(`Signal/Calls/CallMuteControlUpdater.swift:50-90`): conform to
`IndividualCallObserver` and `GroupCallObserver`, add and remove itself as
observer in `didUpdateCall(from:to:)`, and call `callStarted()` only when:

- individual call: `state` is `.connected` (also accept the reconnecting
  state if the enum has one; read `IndividualCall`'s `CallState` and list the
  accepted cases in a comment);
- group call: `ringRtcCall.localDeviceState.joinState == .joined`.

Call `callEnded()` when the call becomes nil, the individual call reaches a
terminal state, or the group call ends or leaves `.joined`.

Put the decision in a pure static function, for example
`static func shouldRun(individualState: CallState?) -> Bool` and
`static func shouldRun(joinState: JoinState?) -> Bool`, and unit-test those
two functions for every enum case (use a `switch` with no `default` so a new
upstream case fails to compile rather than being silently ignored).

Verify: `SWIFT_TEST MuteTriggerCoordinatorTest` succeeds, including the
existing start/stop tests, which should keep working through the
`callStarted()` / `callEnded()` entry points.

**DEVICE check:** with head tilt enabled and Motion permission not yet
granted, receive a call. Expected: no permission prompt while ringing; the
prompt appears after answering.

**5.2 Keep Now Playing claimed for the whole call (B4).**

In `TrackSkipMuteTrigger`:

- Extract `private func claimNowPlayingIfUnclaimed()` from `start()`.
- In `start()`, also schedule a repeating `Timer` every 5 seconds that calls
  it; keep the timer in a property; invalidate it in `stop()`.
- In `stop()`, remove `command.isEnabled = false`. Removing the target is
  enough, and other code in Signal may enable those commands in future.

To make it testable, inject the two system objects behind a tiny protocol
(`var nowPlayingInfo: [String: Any]? { get set }`) with
`MPNowPlayingInfoCenter.default()` as the default. New test class
`TrackSkipMuteTriggerTest`: start with a foreign `nowPlayingInfo`, clear it,
call `claimNowPlayingIfUnclaimed()` (make it `internal` for the test), and
assert the Signal title is set; then `stop()` and assert it is cleared; and
assert `stop()` does not clear a foreign title.

Verify: `SWIFT_TEST TrackSkipMuteTriggerTest MuteTriggerCoordinatorTest`.

**DEVICE check:** start a call while a voice message is playing; track skip
still toggles mute. After the call, a music app's track skip works.

**5.3 Quieter, cheaper head tracking (S5, P1).**

- Add a third Settings switch in `Signal/Settings.bundle/Root.plist`:
  title `Log Head Movements`, key `MuteTrigger.headTiltDebugLog`, default
  false. In `HeadTiltMuteTrigger.handle`, log `.movement` events and the
  60-second summary only when that key is true (read it once in `start()`).
  Always keep the `.triggered` log line.
- Deliver motion updates to a private serial `OperationQueue` instead of
  `.main`. Run `detector.process` on that queue (make the detector and the
  counters queue-confined: only touched inside the handler), and hop to the
  main actor with `Task { @MainActor in onTrigger() }` only for `.triggered`.
  `stop()` must still reset the detector; do it by calling
  `queue.addOperation { ... }` after `stopDeviceMotionUpdates()`.

Verify: `SWIFT_TEST HeadTiltDetectorTest MuteTriggerCoordinatorTest` succeeds
with the same test count as the baseline, and the build has no new
concurrency warnings (the project builds with warnings as errors unless
`User.xcconfig` relaxes that).

**DEVICE check:** head tilt still toggles mute, backgrounded and locked.

---

### Stage 6: Call screen and Control Center (fixes B5, B6, P2)

Prefix `[mute-triggers]`.

**6.1 Give up key focus when minimized (B5).** DEVICE-led.

First ask the owner to reproduce: in a call, minimize to picture-in-picture,
open the chat list, press Space and the arrow keys on a hardware keyboard.
If mute does **not** toggle, skip this step and record "B5 not reproducible".

If it does: in both `GroupCallViewController` and
`IndividualCallViewController`, call `resignFirstResponder()` on the line
after `isCallMinimized = true` (`GroupCallViewController.swift:1997`,
`IndividualCallViewController.swift:1122`). The existing
`becomeFirstResponder()` calls on return from picture-in-picture already
restore it.

Verify: app builds; owner repeats the reproduction.

**6.2 Cache the shared defaults (P2).**

In `SignalControls/CallMuteControlState.swift`, change `defaults` from a
computed property to `private static let defaults: UserDefaults? = { ... }()`.

Verify: the app and the `SignalControls` target both build
(`xcodebuild build -workspace Signal.xcworkspace -scheme Signal -destination
'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`).

**6.3 Make stale state expire (B6).**

- In `CallMuteControlState`, also store `CallMuteControl.updatedAt`
  (`Date().timeIntervalSince1970`) on every write.
- In `CallMuteControlUpdater`, while a call is active, re-store the value
  every 60 seconds (a `Timer` started and stopped in `didUpdateCall`). This
  refreshes the timestamp without reloading the control.
- In `CallMuteControl.Provider.currentValue()`, return `false` if
  `updatedAt` is older than 180 seconds.

Put the freshness rule in a pure static function
`CallMuteControlState.displayedValue(isMuted:updatedAt:now:)` and unit-test
it (fresh muted is true; stale muted is false; missing timestamp is false).
Extend `CallMuteControlUpdaterTest` to check the store closure is called with
the current value.

Verify: `SWIFT_TEST CallMuteControlUpdaterTest` plus the new test class.

---

### Stage 7: Tests for the production call path, and docs (fixes A2, A5, S4)

**7.1 Test `SignalCallMuteTarget`'s decisions (A2).** Prefix `[app-intents]`.

The class needs a live `CallService`, which is impractical in a unit test.
Instead, extract its two pure decisions into static functions on
`CallMuteController` and test those:

- `static func isRingingUnanswered(_ state: CallState) -> Bool`
- `static func canApplyDirectly(isMuted: Bool, recordPermission: AVAudioSession.RecordPermission) -> Bool`
  (the condition on `CallMuteController.swift:181`)

Have `SignalCallMuteTarget` call them. Add tests covering every `CallState`
case for the first and all four input combinations for the second.

Verify: `SWIFT_TEST CallMuteControllerTest`.

**7.2 Update the fork docs (A5, S4, B3).** Prefix `[mute-triggers]`.
Files: `Fork/README.md`, `Fork/ROADMAP.md`, `Fork/PLAN.md`.

- README: fix "This folder exists only on the `mute-triggers` branch and
  above" wording so it is not misread; describe the mute and unmute tones;
  document the new "Log Head Movements" switch; add a short "Security notes"
  section stating the accepted risk from S4 (intents and the control work on
  a locked phone, by design) and that `release.py` now refuses to overwrite
  remote-only commits.
- ROADMAP: mark the earcon item done; correct "Sources start on call connect"
  only if Stage 5.1 was skipped.
- PLAN: append a "Phase 4: review fixes" section listing the stages of this
  file with their checkboxes.
- Move this file's still-open DEVICE checks into that section.

Verify:

```bash
grep -n "live()" Fork/*.md
```

prints nothing, and every relative link in the three files points at a file
that exists.

---

### Stage 8: Hand back to the owner (not for the executing agent)

The executing agent stops after Stage 7 and writes a final report containing:

1. Each step: done, skipped (with reason), or failed (with command output).
2. Baseline versus final test counts for Python and Swift.
3. The list of DEVICE checks still to be performed.
4. `git log --oneline personal..review-fixes`.

The owner then:

- Runs the DEVICE checks from a local build of `review-fixes`.
- Moves each commit into its layer, using the `[layer]` prefix as the guide
  (`git rebase -i --update-refs` from `personal`, per `Fork/README.md`
  "Keeping the layers clean"), and removes the prefixes.
- Confirms each layer still builds alone (`PLAN.md` CP0.4).
- Pushes the stack and confirms the new `fork` workflow is green.

---

## Appendix: finding to step map

| Finding | Step | | Finding | Step |
|---|---|---|---|---|
| S1 | 4.1 (4.2 optional) | | B6 | 6.3 |
| S2 | 1.1 | | B7, B8, B10, B11 | 1.5 |
| S3 | 1.2 | | B9 | 1.6 |
| S4 | 7.2 (document only) | | P1 | 5.3 |
| S5 | 5.3 | | P2 | 6.2 |
| S6 | 1.3 | | P3 | 1.5 |
| S7 | 1.4 | | A1 | 2.1 |
| B1 | 3.1 | | A2 | 1.x tests, 5.2, 7.1 |
| B2 | 3.2, 3.3 | | A3 | no action |
| B3 | 5.1 | | A4 | no action unless upstreaming |
| B4 | 5.2 | | A5 | 7.2 |
| B5 | 6.1 | | | |

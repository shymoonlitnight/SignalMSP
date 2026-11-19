# SignalMSP follow-up plan (second review)

Reviewed: branch `personal` at `a91cada` (2026-11-16). This follows the first
review plan, whose stages are recorded in `Fork/PLAN.md` "Phase 4: Review
fixes". No new High or Medium defects were found. Six items remain; three are
small code changes (Part 2), three are for the owner (Part 3).

Limits of the review: static reading only. Nothing was compiled or run, and
the state of the `fork` GitHub workflow could not be seen.

## Part 1: Rules for whoever executes Part 2

Same rules as the first plan. In short:

1. Work on a new branch `review-followup` created from `personal`. One commit
   per step. Start each commit subject with `[mute-triggers]`.
2. No `git rebase`, no force-push, no amending existing commits, no pushing.
3. Never run `Fork/release.py` without a subcommand, and never with `--yes`.
   Only `Fork/release.py self-test` is allowed.
4. Edit only the files a step names. If a step seems to need another file,
   stop and report.
5. A step is done only when its Verify passes. If it fails twice for a reason
   that isn't obvious, stop, leave the work uncommitted, and report the command
   and its full output.
6. Never weaken or delete an existing test.

Setup:

```bash
git checkout personal
```

```bash
git checkout -b review-followup
```

```bash
Fork/release.py self-test
```

The last line must be `self-test ok` before any change is made.

## Part 2: Code steps

### Step 1: `confirm()` must stop cleanly without a terminal

File: `Fork/release.py` only.

Problem: `confirm()` calls `input()`. The archive-mismatch prompt now asks even
with `--yes`, so when the script runs with no stdin (for example from the
`term` wrapper), `input()` raises `EOFError`. `main()` catches only `Stop` and
`KeyboardInterrupt`, so the user gets a traceback.

Change `confirm()` (near line 122) so the `input()` call is wrapped:

```python
def confirm(query, yes=False):
    if yes:
        log(query)
        return True
    try:
        return input(f'{query}? [y/N] ').strip().lower() in ('y', 'yes')
    except EOFError:
        raise Stop(f'{query}: needs an answer, but there is no terminal to ask on',
                   're-run from a terminal')
```

Test: add a function `_test_confirm()` next to `_test_redact()` and call it
from `self_test()` after `_test_redact()`. It must:

- save `sys.stdin`, replace it with `io.StringIO('')` (add `import io` to the
  imports, in alphabetical position), and restore it in a `finally`;
- assert `confirm('upload', yes=True)` returns `True`;
- assert `confirm('upload')` raises `Stop` whose message contains
  `no terminal`;
- set `sys.stdin = io.StringIO('y\n')` and assert `confirm('upload')` returns
  `True`.

Verify:

```bash
Fork/release.py self-test
```

prints `self-test ok`. Then temporarily remove the `try`/`except` and confirm
the self-test fails with `EOFError`; restore it.

### Step 2: Mark the head-tilt motion handler `@Sendable`

File: `Signal/ForkExtras/HeadTiltMuteTrigger.swift` only. Needs macOS + Xcode.

Problem: the closure passed to `manager.startDeviceMotionUpdates(to: queue)`
is written inside a `@MainActor` method but runs on a background queue. In the
project's current Swift 5 mode this is safe. If the project moves to Swift 6
mode, a closure the compiler treats as main-actor-isolated traps at runtime
when called off the main thread.

Change (in `start(onTrigger:)`, near line 190): add `@Sendable` to the closure.

```swift
manager.startDeviceMotionUpdates(to: queue) { @Sendable [weak self] motion, error in
```

Do not change anything else in the closure. If the compiler then reports an
error about capturing `onTrigger` or `self`, stop and report the exact error
rather than working around it.

Verify (replace `<SIM>` with a name from
`xcrun simctl list devices available | grep -m1 iPhone`):

```bash
xcodebuild test -workspace Signal.xcworkspace -scheme Signal -destination 'platform=iOS Simulator,name=<SIM>' CODE_SIGNING_ALLOWED=NO -only-testing:SignalTests/HeadTiltDetectorTest -only-testing:SignalTests/MuteTriggerCoordinatorTest
```

ends with `** TEST SUCCEEDED **`, with no new warnings from
`HeadTiltMuteTrigger.swift`.

DEVICE check for the owner (already listed in `Fork/PLAN.md`): head tilt still
toggles mute with the call screen open, backgrounded and locked.

### Step 3: Run every fork test class in the workflow

File: `.github/workflows/fork.yml` only.

Problem: the `swift-tests` job lists six test classes. Two added by the review
fixes are missing.

Change: in the `xcodebuild test` command, after the line for
`MuteTriggerCoordinatorTest`, add a trailing ` \` to that line and append:

```
            -only-testing:SignalTests/TrackSkipMuteTriggerTest \
            -only-testing:SignalTests/CallMuteControlStateTest
```

Verify:

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/fork.yml')); s=d['jobs']['swift-tests']['steps'][-1]['run']; assert s.count('-only-testing:') == 8, s"
```

exits 0. Then confirm each of the eight names is a real class:

```bash
grep -rhoE "final class [A-Za-z]+Test: XCTestCase" SignalTests/Calls/CallMute*.swift SignalTests/ForkExtras/
```

must list all eight names used in the workflow.

Do not change the runner or the Xcode path in this step; see Part 3, item B.

### Final report

After Step 3, stop and report: each step as done, skipped or failed; the
self-test result; the Swift test result; and
`git log --oneline personal..review-followup`.

## Part 3: For the owner

**A. Move the commits into the stack.** The 16 review commits, plus the three
above, sit on top of `personal` with `[app-intents]` / `[mute-triggers]`
prefixes. Until they are moved, `app-intents` lacks the call re-check fix and
the workflow file exists only on `personal`. Use
`git rebase -i --update-refs` from `personal` as described in
`Fork/README.md` "Keeping the layers clean", drop the prefixes, confirm each
layer builds alone (`PLAN.md` CP0.4), then push the stack.

**B. Run the `fork` workflow by hand once** (Actions → fork → Run workflow).
The Swift job sets `DEVELOPER_DIR=/Applications/Xcode_27.1.app` on
`macos-latest`. Upstream's `main.yml` uses different runners. If the job fails
at "Check Xcode version" or earlier, copy the runner label from upstream's
`build_and_test` job matrix into `runs-on:`.

**C. Device checks.** All of them in `Fork/PLAN.md` Phase 4 are still
unticked. Two notes from the second review:

- *Tones and track skip* should pass. The tone's player does not clear Now
  Playing, because the call's own audio activity keeps background playback
  wanted for the whole call.
- *Control Center after a force-quit* will probably fail. The 180-second
  rule is applied only when iOS asks the extension for its value, and once the
  app is dead nothing requests a reload. If the control still shows Muted
  after three minutes, the app cannot fix this from its side. Change the
  sentence in `Fork/README.md` that says a stale muted state "shows as
  unmuted" to say it corrects itself the next time iOS refreshes the control
  or Signal is opened. Tapping the control still works either way, because the
  intent toggles the call's real state.

**D. Decision still open:** direction-specific head tilt (left mutes, right
unmutes) instead of toggle.

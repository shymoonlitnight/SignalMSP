# SignalMSP: personal fork notes

This fork of [Signal-iOS](https://github.com/signalapp/Signal-iOS) adds hands-free
microphone mute/unmute during calls (Shortcuts, Action Button, Back Tap, etc.).
The goal is muting without touching the screen, e.g. outdoors wearing gloves.

This folder exists only on the `personal` branch. Upstream's own docs
(`BUILDING.md`, `CONTRIBUTING.md`) still apply; this file covers what's different.

See [ROADMAP.md](ROADMAP.md) for planned work and [PLAN.md](PLAN.md) for the
implementation checkpoints.

## Branches

| Branch | Contents |
|---|---|
| `upstream/main` | Signal's code. Never commit here; just `git fetch upstream`. |
| `app-intents` | Upstream plus the call-mute App Intents (`Signal/Shortcuts/CallMuteShortcuts.swift`). Meant to stay upstreamable. |
| `mute-triggers` | `app-intents` plus fork-only mute triggers (and, for now, the registration ID fix). Never sent upstream. |
| `personal` | `mute-triggers` plus personal build config: xcconfig defaults, icon, entitlements, and these notes. This is what gets built, and is the fork's default branch on GitHub. |
| `regid-warnings` | Side branch: upstream plus the registration ID fix only, for its own upstream PR. Not part of the stack. |

The old `main` branch was retired on 2026-10-23; `app-intents` replaced it.

Remotes: `origin` is the fork (`shymoonlitnight/SignalMSP`), `upstream` is
`signalapp/Signal-iOS`.

See [ROADMAP.md](ROADMAP.md#branch-restructure) for what goes on each layer.

### Updating from upstream

`Fork/release.py` does this as its first step (see
[Releasing to TestFlight](#4-releasing-to-testflight)); skip the build with
`Fork/release.py --no-clean --no-archive --no-upload`. By hand, one rebase
from `personal` moves every branch below it:

```sh
git config rerere.enabled true      # reuse earlier conflict resolutions
git checkout personal
git fetch upstream
git rebase --update-refs upstream/main   # Git 2.38+; also moves app-intents and mute-triggers
git push --force-with-lease origin app-intents mute-triggers personal
make dependencies
```

Each fork commit is kept as is. Don't squash them; `app-intents`' commits are
meant to be sent upstream separately.

### Keeping the layers clean

- Upstreamable work is committed on `app-intents`, fork-only triggers on
  `mute-triggers`, never on `personal`. If you happen to be on `personal`, use `git commit --fixup` and
  rebase, or check out the lower branch to commit.
- Lower branches must never depend on higher ones. Every so often, check out
  `app-intents` and build it on its own.
- Put personal config in `Config/User.xcconfig`, not `project.pbxproj`.
  pbxproj conflicts are painful.

## Making a personalized build

### 1. Setup

Follow upstream `BUILDING.md` steps 1 and 2 (clone with submodules,
`make dependencies`), then:

```sh
git checkout personal
cp Config/User.xcconfig.sample Config/User.xcconfig   # if you don't have one yet
open Signal.xcworkspace
```

You don't need to change the Team dropdown on each target as `BUILDING.md`
describes. The `personal` branch reads team and bundle IDs from xcconfig.

### 2. `Config/User.xcconfig`

`Config/Project.xcconfig` ends with `#include? "User.xcconfig"`, so anything
in `User.xcconfig` overrides the project settings. The file is gitignored
(`Config/User*.xcconfig`), which keeps your team ID and bundle IDs out of the repo.

On `personal`, the values upstream hard-codes in `project.pbxproj` were moved
into `Config/Project.xcconfig` as defaults, so `User.xcconfig` can override them:

| Setting | Upstream default | Purpose |
|---|---|---|
| `DEVELOPMENT_TEAM` | `U68MSDN6DR` | Signing team for all targets. |
| `SIGNAL_BUNDLEID_PREFIX` | `org.whispersystems` | Prefix for the app, extension, and App Group bundle IDs (e.g. `group.$(SIGNAL_BUNDLEID_PREFIX).signal.group`). |
| `SIGNAL_ORG_BUNDLEID_PREFIX` | `org.signal` | **New on `personal`.** Prefix for the framework and test bundles (`SignalUI`, `SignalServiceKit`, and their test targets), which upstream hard-codes as `org.signal.*`. |
| `SIGNAL_MERCHANTID` | `org.signalfoundation` | Apple Pay merchant ID suffix. |
| `SIGNAL_APP_NAME` | `$(TARGET_NAME)` ("Signal") | **New on `personal`.** Home-screen name of the app (`CFBundleDisplayName` in `Signal/Signal-Info.plist`). Extensions keep their own names. |

Example `Config/User.xcconfig`:

```
// Lenient warnings, from User.xcconfig.sample
OTHER_SWIFT_FLAGS = $(inherited) -no-warnings-as-errors

DEVELOPMENT_TEAM = ABCDE12345              // your team ID
SIGNAL_BUNDLEID_PREFIX = org.example
SIGNAL_ORG_BUNDLEID_PREFIX = $(SIGNAL_BUNDLEID_PREFIX)
SIGNAL_MERCHANTID = org.example
SIGNAL_APP_NAME = SignalMSP
```

Tips:
- Pick a bundle prefix you own. Xcode automatic signing registers the App IDs
  and App Group the first time you build.
- If you omit `User.xcconfig`, the build uses upstream's team and IDs and
  won't sign with your account.
- After changing xcconfig values, clean the build folder (⇧⌘K) if signing errors persist.

### 3. Build and run

Choose the `Signal` scheme, your device, then Build & Run. Upstream's known
issue still applies: APNs push only works with Signal's production signing,
so notifications and incoming-call pushes are unreliable on personal builds.

### 4. Releasing to TestFlight

`Fork/release.py` updates from upstream, archives, uploads to App Store
Connect, and sets the TestFlight "What to Test" notes. It needs only Python
3.10+, git, Xcode and openssl (and uses `xcbeautify` if installed).

```sh
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/path/AuthKey_XXXX.p8
Fork/release.py asc-check           # key works, app record exists
Fork/release.py                     # update, clean, archive, upload, notes
Fork/release.py --no-update         # build what's checked in now
Fork/release.py notes 8.34 5 --show # print a build's What to Test text
Fork/release.py self-test           # offline tests of the script
Fork/release.py --help
```

Before the first upload, create the app record for
`$(SIGNAL_BUNDLEID_PREFIX).signal` in App Store Connect (Apps → + → New App).
Build numbers are one past App Store Connect's latest for the version. Each
upload is tagged `testflight/<version>-<build>` locally, which marks where
the next build's "upstream changes since" notes start.

term's `term dev signal_release`, `testflight_notes` and `asc_check` run this
script from the `personal` branch, with the API key from term's secrets.

## Differences from upstream on `personal`

Everything below is in the commit "Personal dev signing, bundle id prefix,
and app icon".

### Signing and bundle IDs (`project.pbxproj`, `Config/Project.xcconfig`)
- Removed the hard-coded `DEVELOPMENT_TEAM`, `SIGNAL_BUNDLEID_PREFIX`, and
  `SIGNAL_MERCHANTID` from the project-level build configurations, and moved
  them to `Config/Project.xcconfig` as overridable defaults.
- Replaced the hard-coded `org.signal.*` bundle IDs on `SignalUI`,
  `SignalUITests`, `SignalServiceKit`, and `SignalServiceKitTests` with
  `$(SIGNAL_ORG_BUNDLEID_PREFIX).*`.
- `Signal/Signal-Info.plist`: `CFBundleDisplayName` is `$(SIGNAL_APP_NAME)`
  instead of `${PRODUCT_NAME}`, so the home-screen name can differ from
  App Store Signal without renaming the product or module.

### App icon (`Signal/AppIcons/AppIcon.icon/icon.json`)
- The background gradient changed from Signal blue to green, in both light and dark
  appearances, so the personal build is easy to tell apart from App Store
  Signal on the same phone. Only the colors changed; the glyph is the same.

### Entitlements
- Removed `com.apple.developer.pushkit.unrestricted-voip` from
  `Signal/Signal-AppStore.entitlements`,
  `SignalNSE/SignalNSE-AppStore.entitlements`, and
  `SignalShareExtension/SignalShareExtension-AppStore.entitlements`.
- Why: Apple grants that entitlement only to approved apps, so a personal team
  can't get a provisioning profile that includes it.
- Effect: VoIP pushes for incoming calls aren't available, so incoming calls
  may not ring when the app is not running. Outgoing calls and the mute
  shortcuts aren't affected.

## Call mute App Intents (on `app-intents`)

`Signal/Shortcuts/CallMuteShortcuts.swift` adds four App Intents (iOS 17+):
**Toggle Microphone Mute**, **Set Microphone Mute**, **Get Microphone Mute
State**, and **Get Active Call State**. They run without opening the app and
return an error when no call is active. Use them from Shortcuts, then attach
the shortcut to the Action Button, Back Tap (Accessibility → Touch → Back Tap),
Full Keyboard Access commands, AssistiveTouch, or Switch Control.

Tests are in `Signal/test/Calls/CallMuteShortcutsTest.swift`.

A separate, unrelated commit logs network failures during the registration
ID check as warnings instead of asserting (`RegistrationIdMismatchManager.swift`).
It lives on `regid-warnings` so it can go upstream as its own PR, and is
carried on `mute-triggers` until then.

## Background

- Signal uses CallKit by default (off in China). AirPods stem press already
  mutes natively through CallKit.
- Signal's existing Siri support uses old SiriKit messaging intents, not the
  App Intents framework. If this is pitched upstream, frame it as accessibility
  (motor disabilities, Switch Control, keyboard users). The intents expose only
  call state, no contacts or content. Signal is slow to respond to outside
  contributions; a forum feature request from about a year ago got no replies.

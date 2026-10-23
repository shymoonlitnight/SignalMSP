#!/usr/bin/env python3
'''
Update SignalMSP from upstream Signal-iOS, then build and upload it to TestFlight.

    Fork/release.py                    update, clean, archive, upload, set What to Test
    Fork/release.py --no-update        skip the upstream update (any step can be skipped)
    Fork/release.py notes 8.34 5       set (or --show) a build's What to Test text
    Fork/release.py asc-check          check the App Store Connect key and app record
    Fork/release.py self-test          offline tests of the local pieces

Steps of a release:
1. update: fetch upstream, rebase the branch stack (app-intents, mute-triggers, personal) onto
   upstream/main in one `git rebase --update-refs`, keeping each fork commit,
   force-push the stack to origin, then `make dependencies`
2. clean: drop the build stamp from the info plists, xcodebuild clean
   (and with --derived-data, delete Signal's DerivedData)
3. archive: App Store Release archive into Xcode's Archives (shows in Organizer),
   numbered one past the latest build App Store Connect has for this version
4. upload: export a signed .ipa and upload it with altool (xcodebuild's own
   upload rejects the API key: "Cannot verify client's JWT headers"), tag the
   commit testflight/<version>-<build>, and once App Store Connect lists the
   build, set its TestFlight What to Test text

Signing is automatic, using DEVELOPMENT_TEAM from Config/User.xcconfig. The App
Store Connect app record for the bundle id has to exist already.

The App Store Connect API key comes from the environment:
    ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the AuthKey_<id>.p8 file)

Only needs the Python standard library, git, Xcode, and openssl.
xcbeautify is used for build output if it's installed.
'''

import argparse
import base64
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

repo_default = Path(__file__).resolve().parent.parent
info_plists = ('Signal/Signal-Info.plist', 'SignalShareExtension/Info.plist', 'SignalNSE/Info.plist')
configuration = 'App Store Release'
archives_dir = Path.home() / 'Library/Developer/Xcode/Archives'

testflight_notes_limit = 4000  # App Store Connect's whatsNew limit
testflight_tag_prefix = 'testflight/'

# upstream housekeeping commits that say nothing about what to test
upstream_noise = re.compile(r'^(Update translations|Update release notes|Bump (build|version)|Merge |'
                            r'Use Xcode \d+|Update (Podfile|Pods|submodule|dependencies))', re.I)


class Stop(Exception):
    '''a step can't continue; message plus what to do about it'''

    def __init__(self, what, *steps):
        super().__init__(what)
        self.steps = steps


# ---------------------------------------------------------------------
# helpers

use_color = sys.stderr.isatty()


def log(*args, style=None):
    colors = {'do': '36', 'ok': '32', 'warn': '33', 'error': '31'}
    text = ' '.join(map(str, args))
    if use_color and style in colors:
        text = f'\033[{colors[style]}m{text}\033[0m'
    print(text, file=sys.stderr, flush=True)


def run(*args, check=True, capture=False, input=None, cwd=None, quiet=False):
    args = [str(aa) for aa in args]
    if not quiet:
        log(' '.join(args), style='do')
    return subprocess.run(args, check=check, input=input, cwd=cwd,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def git(repo, *args):
    '''git output as a stripped string; raises on failure'''
    return run('git', '-C', repo, *args, capture=True, quiet=True).stdout.decode().strip()


def git_try(repo, *args):
    '''git's CompletedProcess, without raising on failure'''
    return run('git', '-C', repo, *args, check=False, capture=True, quiet=True)


def git_lines(repo, *args):
    out = git_try(repo, *args)
    return [ll for ll in out.stdout.decode().splitlines() if ll.strip()] if not out.returncode else []


def is_ancestor(repo, a, b):
    return git_try(repo, 'merge-base', '--is-ancestor', a, b).returncode == 0


def confirm(query, yes=False):
    if yes:
        log(query)
        return True
    return input(f'{query}? [y/N] ').strip().lower() in ('y', 'yes')


def xcconfig(repo):
    '''DEVELOPMENT_TEAM etc. from Config/User.xcconfig (falling back to Config/Project.xcconfig)'''
    values = {}
    for name in ('Project.xcconfig', 'User.xcconfig'):
        conf = repo / 'Config' / name
        if conf.exists():
            for line in conf.read_text().splitlines():
                if m := re.match(r'\s*([A-Z_]+)\s*=\s*(.*?)\s*(//.*)?$', line):
                    values[m.group(1)] = m.group(2)
    return values


def app_bundle_id(repo):
    prefix = xcconfig(repo).get('SIGNAL_BUNDLEID_PREFIX')
    if not prefix:
        raise Stop(f'SIGNAL_BUNDLEID_PREFIX not set in {repo}/Config/User.xcconfig')
    return f'{prefix}.signal'


def restore_plists(repo):
    '''
    undo the BuildDetails stamp Scripts/update_plist_info.sh writes into the
    info plists on every build, and the build number set before archiving,
    leaving any other plist edits alone
    '''
    generated = ('BuildDetails', 'CFBundleVersion')
    for rel in info_plists:
        plist = repo / rel
        head = git_try(repo, 'show', f'HEAD:{rel}')
        if not plist.exists() or head.returncode:
            continue
        current, committed = plistlib.loads(plist.read_bytes()), plistlib.loads(head.stdout)
        if current == committed:
            continue
        for kk in generated:
            current.pop(kk, None)
            committed.pop(kk, None)
        if current == committed:
            git(repo, 'checkout', '--', rel)
            log(f'restored {rel} (build stamp/number only)')
        else:
            log(f'warning: {rel} has local edits besides the build stamp/number, leaving it', style='warn')


def set_build_number(repo, number):
    for rel in info_plists:
        run('/usr/libexec/PlistBuddy', '-c', f'Set :CFBundleVersion {number}', repo / rel, quiet=True)


def xcodebuild(*args, warnings=False):
    '''
    run xcodebuild through xcbeautify: errors only, or with warnings=True also
    the (mostly third-party Pods) warnings, one line each. raises on failure
    '''
    args = [str(aa) for aa in args]
    log('xcodebuild', *args, style='do')
    beautify = shutil.which('xcbeautify')
    if not beautify:
        return run('xcodebuild', *args, '-quiet', quiet=True)
    build = subprocess.Popen(['xcodebuild', *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert build.stdout
    subprocess.run([beautify, '--quiet' if warnings else '--quieter', '--disable-logging'], stdin=build.stdout)
    build.stdout.close()
    if build.wait():
        raise subprocess.CalledProcessError(build.returncode, ['xcodebuild', *args])


# ---------------------------------------------------------------------
# App Store Connect API

def asc_key():
    '''(key_id, issuer_id, key_path) from ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH, or None'''
    key_id, issuer_id, key_path = (os.environ.get(kk, '') for kk in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH'))
    if not (key_id and issuer_id and key_path):
        return None
    key_path = Path(key_path).expanduser()
    if not key_path.exists():
        raise Stop(f'ASC_KEY_PATH, {key_path}, not found')
    return key_id, issuer_id, key_path


def asc_auth_args():
    '''xcodebuild args for the API key; without it xcodebuild uses the account in Xcode > Settings > Accounts'''
    key = asc_key()
    if not key:
        return []
    key_id, issuer_id, key_path = key
    return ['-authenticationKeyPath', key_path, '-authenticationKeyID', key_id,
            '-authenticationKeyIssuerID', issuer_id]


def asc_token():
    '''short-lived App Store Connect API JWT (ES256), signed with the system openssl'''
    key = asc_key()
    if not key:
        raise Stop('no App Store Connect API key', 'set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH')
    key_id, issuer_id, key_path = key

    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b'=')

    now = int(time.time())
    header = b64(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
    claims = b64(json.dumps({'iss': issuer_id, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}).encode())
    signing_input = header + b'.' + claims

    der = run('openssl', 'dgst', '-sha256', '-sign', key_path, input=signing_input, capture=True, quiet=True).stdout

    # openssl gives a DER SEQUENCE of two INTEGERs; JWT wants raw 32-byte r || s
    def der_int(buf, pos):
        assert buf[pos] == 0x02, 'unexpected signature format'
        length = buf[pos + 1]
        return int.from_bytes(buf[pos + 2:pos + 2 + length], 'big'), pos + 2 + length

    pos = 2 if der[1] < 0x80 else 3
    r, pos = der_int(der, pos)
    s, _ = der_int(der, pos)
    signature = b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))
    return (signing_input + b'.' + signature).decode()


def asc_request(method, endpoint, body=None, **params):
    url = f'https://api.appstoreconnect.apple.com/v1/{endpoint}'
    if params:
        url += '?' + urllib.parse.urlencode(params)
    headers = {'Authorization': f'Bearer {asc_token()}'}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read() or b'{}')
    except urllib.error.HTTPError as e:
        errors = json.loads(e.read() or b'{}').get('errors', [])
        detail = '; '.join(ee.get('detail') or ee.get('title', '') for ee in errors)
        raise Stop(f'App Store Connect API {e.code}: {detail or e.reason}')


def asc_get(endpoint, **params):
    return asc_request('GET', endpoint, **params)


def asc_app_id(bundle_id):
    apps = asc_get('apps', **{'filter[bundleId]': bundle_id, 'fields[apps]': 'name'})['data']
    if not apps:
        raise Stop(f'no App Store Connect app record for {bundle_id}',
                   'create it in App Store Connect > Apps > + > New App')
    return apps[0]['id']


def asc_next_build_number(bundle_id, version):
    '''one more than the highest build number App Store Connect has for this version'''
    builds = asc_get('builds', limit=200, **{'filter[app]': asc_app_id(bundle_id),
                                             'filter[preReleaseVersion.version]': version,
                                             'fields[builds]': 'version'})['data']
    numbers = [int(bb['attributes']['version']) for bb in builds if bb['attributes']['version'].isdigit()]
    return max(numbers, default=0) + 1


def asc_set_whats_new(bundle_id, version, build, notes, wait=0, locale='en-US'):
    '''
    set a build's TestFlight What to Test text. the build only shows up in the
    api a few minutes after upload, so wait up to `wait` minutes for it
    '''
    app_id = asc_app_id(bundle_id)
    deadline = time.time() + wait * 60
    while True:
        builds = asc_get('builds', **{'filter[app]': app_id, 'filter[version]': str(build),
                                      'filter[preReleaseVersion.version]': str(version)})['data']
        if builds or time.time() >= deadline:
            break
        log(f'waiting for App Store Connect to list {version} ({build})…')
        time.sleep(60)
    if not builds:
        return False
    build_id = builds[0]['id']

    localizations = asc_get(f'builds/{build_id}/betaBuildLocalizations')['data']
    existing = next((ll for ll in localizations if ll['attributes'].get('locale') == locale), None)
    if existing:
        asc_request('PATCH', f"betaBuildLocalizations/{existing['id']}", {'data': {
            'type': 'betaBuildLocalizations', 'id': existing['id'], 'attributes': {'whatsNew': notes}}})
    else:
        asc_request('POST', 'betaBuildLocalizations', {'data': {
            'type': 'betaBuildLocalizations', 'attributes': {'locale': locale, 'whatsNew': notes},
            'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})
    return True


# ---------------------------------------------------------------------
# archives and What to Test notes

def archive_info(archive_path):
    '''version, build number, bundle id and source commit recorded in an archive'''
    app_plist = next(Path(archive_path, 'Products', 'Applications').glob('*.app/Info.plist'))
    info = plistlib.loads(app_plist.read_bytes())
    commit = (info.get('BuildDetails', {}).get('SignalCommit') or '').split(' ')[0] or None
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'bundle_id': info['CFBundleIdentifier'], 'commit': commit}


def all_archives(scheme):
    return sorted(glob.glob(str(archives_dir / f'*/{scheme} *.xcarchive')), key=os.path.getmtime, reverse=True)


def find_archive(scheme, version, build):
    for aa in all_archives(scheme):
        try:
            info = archive_info(aa)
        except (StopIteration, KeyError, OSError):
            continue
        if info['version'] == str(version) and info['build'] == str(build):
            return Path(aa), info
    return None, None


def testflight_notes(repo, commit, tag=None):
    '''
    What to Test text for a build of `commit`: upstream's release notes for the
    version, the fork's own commits, and upstream commits since the last
    testflight/* tag (other than `tag`, this build's own)
    '''
    def bullets(subjects, limit):
        shown = [f'• {ss}' for ss in subjects[:limit]]
        if len(subjects) > limit:
            shown.append(f'…and {len(subjects) - limit} more')
        return '\n'.join(shown)

    sections = []

    release_notes = '\n'.join(git_lines(repo, 'show', f'{commit}:fastlane/metadata/en-US/release_notes.txt'))
    if release_notes:
        sections.append(f'Signal release notes:\n{release_notes}')

    fork = git_lines(repo, 'log', '--no-merges', '--reverse', '--format=%s', f'upstream/main..{commit}')
    if fork:
        sections.append(f'In this fork:\n{bullets(fork, 15)}')

    # the fork's branches are rebased each update, so older tags aren't ancestors
    # of `commit`; the newest other tag is the previous build
    previous = next((tt for tt in git_lines(repo, 'tag', '--list', f'{testflight_tag_prefix}*',
                                            '--sort=-creatordate') if tt != tag), None)
    if previous:
        base = git_lines(repo, 'merge-base', commit, 'upstream/main')
        if base:
            upstream = [ss for ss in git_lines(repo, 'log', '--no-merges', '--format=%s', f'{previous}..{base[0]}')
                        if not upstream_noise.match(ss)]
            if upstream:
                sections.append(f'Upstream changes since {previous.removeprefix(testflight_tag_prefix)}:\n'
                                f'{bullets(upstream, 40)}')

    notes = '\n\n'.join(sections) or 'Updated from upstream Signal.'
    if len(notes) > testflight_notes_limit:
        notes = notes[:testflight_notes_limit - 1].rsplit('\n', 1)[0] + '\n…'
    return notes


# ---------------------------------------------------------------------
# update from upstream

def submodule_paths(repo):
    if not (repo / '.gitmodules').exists():
        return []
    return [ll.split(' ', 1)[1] for ll in git_lines(repo, 'config', '--file', '.gitmodules',
                                                       '--get-regexp', r'\.path$') if ' ' in ll]


def stack_branches(repo, branch, upstream='upstream/main'):
    '''local branches below `branch` that carry fork commits, i.e. that --update-refs will move'''
    stack = []
    for bb in git_lines(repo, 'for-each-ref', '--format=%(refname:short)', 'refs/heads'):
        if bb != branch and is_ancestor(repo, bb, branch) and not is_ancestor(repo, bb, upstream):
            stack.append(bb)
    return stack


def left_behind_branches(repo, branch, upstream='upstream/main'):
    '''local branches that share fork commits with `branch` but have commits it lacks.
    --update-refs wouldn't carry those commits along, so they'd be left behind.'''
    left = []
    for bb in git_lines(repo, 'for-each-ref', '--format=%(refname:short)', 'refs/heads'):
        if bb == branch or is_ancestor(repo, bb, branch) or is_ancestor(repo, bb, upstream):
            continue
        base = git_try(repo, 'merge-base', bb, branch)
        if base.returncode == 0 and not is_ancestor(repo, base.stdout.decode().strip(), upstream):
            left.append(bb)
    return left


def update(repo, branch, yes=False, make: str | None = 'dependencies'):
    '''rebase `branch` and the branches below it onto upstream/main, push them, and make dependencies'''
    upstream = 'upstream/main'

    for marker in ('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD'):
        if (repo / git(repo, 'rev-parse', '--git-path', marker)).exists():
            raise Stop(f'a git operation is already in progress ({marker})',
                       'finish it (git rebase --continue) or abort it, then re-run')
    if dirty := git(repo, 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=dirty'):
        raise Stop('working tree has uncommitted changes', *dirty.splitlines(), 'commit or stash them, then re-run')

    run('git', '-C', repo, 'fetch', 'upstream')
    run('git', '-C', repo, 'fetch', 'origin')

    # anything committed on a lower branch that personal doesn't have yet would be left behind
    for bb in left_behind_branches(repo, branch, upstream):
        raise Stop(f"'{bb}' has commits that '{branch}' doesn't",
                   f'rebase {branch} onto it first (git rebase --update-refs {bb} {branch}), then re-run')

    stack = stack_branches(repo, branch, upstream)
    behind = int(git(repo, 'rev-list', '--count', f'{branch}..{upstream}'))
    pushed = [*stack, branch]

    if git(repo, 'rev-parse', '--abbrev-ref', 'HEAD') != branch:
        run('git', '-C', repo, 'checkout', branch)

    if behind:
        if not confirm(f"rebase {', '.join(pushed)} onto {upstream} (+{behind} commits), "
                       f'then force-push them to origin', yes):
            raise Stop('cancelled')
        rebase = run('git', '-C', repo, '-c', 'rerere.enabled=true', 'rebase', '--update-refs', upstream,
                     check=False)
        if rebase.returncode:
            raise Stop(f"rebasing '{branch}' onto {upstream} conflicted",
                       'resolve the conflicts, then: git add <files> && git rebase --continue',
                       "check `git submodule status`: don't commit a stale submodule pointer",
                       'then re-run with --no-update (and push the stack: '
                       f"git push --force-with-lease origin {' '.join(pushed)})")
    else:
        log(f'{branch} is already on {upstream}')

    # the fork never changes submodules; a difference means a stale pointer got committed
    stale = [ss for ss in submodule_paths(repo)
             if git_try(repo, 'rev-parse', f'{branch}:{ss}').stdout != git_try(
                 repo, 'rev-parse', f'{upstream}:{ss}').stdout]
    if stale:
        raise Stop(f"'{branch}' has submodule pointers that differ from {upstream}: {', '.join(stale)}",
                   'fix them with git checkout upstream/main -- <path> in the commit that changed them')

    out_of_date = [bb for bb in pushed
                   if git(repo, 'rev-parse', bb) != git_try(repo, 'rev-parse', f'origin/{bb}').stdout.decode().strip()]
    if out_of_date:
        if confirm(f"force-push {', '.join(out_of_date)} to origin", yes):
            run('git', '-C', repo, 'push', '--force-with-lease', 'origin', *out_of_date)

    run('git', '-C', repo, 'submodule', 'update', '--init', '--recursive')
    if make:
        run('make', make, cwd=repo)


# ---------------------------------------------------------------------
# commands

def release(repo, branch='personal', scheme='Signal', do_update=True, clean=True, archive=True, upload=True,
            derived_data=False, yes=False, warnings=False, notes=None, notes_wait=30):
    workspace = repo / 'Signal.xcworkspace'
    if not workspace.exists():
        raise Stop(f'{workspace} not found')

    xcode_check = run(repo / 'Scripts' / 'check_xcode_version.py', '--relaxed', cwd=repo, check=False)
    if xcode_check.returncode and not confirm('Xcode version differs from .xcode-version, continue anyway', yes):
        return

    # every build dirties Signal-Info.plist, which would block the update
    restore_plists(repo)

    if do_update:
        update(repo, branch, yes=yes)
    elif git(repo, 'rev-parse', '--abbrev-ref', 'HEAD') != branch:
        run('git', '-C', repo, 'checkout', branch)
        run('git', '-C', repo, 'submodule', 'update', '--init', '--recursive')

    build_args = ['-workspace', workspace, '-scheme', scheme, '-configuration', configuration]
    info = plistlib.loads((repo / info_plists[0]).read_bytes())
    version = info['CFBundleShortVersionString']

    # -- clean

    if clean:
        if derived_data:
            for dd in glob.glob(str(Path.home() / 'Library/Developer/Xcode/DerivedData/Signal-*')):
                log(f'rm {dd}')
                shutil.rmtree(dd, ignore_errors=True)
        try:
            xcodebuild(*build_args, '-destination', 'generic/platform=iOS', 'clean', warnings=warnings)
        except subprocess.CalledProcessError:
            raise Stop('xcodebuild clean failed')

    # -- archive

    archive_path = None
    if archive:
        build_number = None
        if asc_key():
            build_number = asc_next_build_number(app_bundle_id(repo), version)
        else:
            log('warning: no App Store Connect key, keeping the build number from the plists', style='warn')

        now = datetime.now()
        archive_path = (archives_dir / now.strftime('%Y-%m-%d')
                        / f"{scheme} {version} ({build_number or info['CFBundleVersion']}) "
                          f"{now.strftime('%H.%M.%S')}.xcarchive")
        try:
            if build_number:
                set_build_number(repo, build_number)
            xcodebuild(*build_args, '-destination', 'generic/platform=iOS', '-archivePath', archive_path,
                       '-allowProvisioningUpdates', *asc_auth_args(), 'archive', warnings=warnings)
        except subprocess.CalledProcessError:
            raise Stop('archive failed', f're-run with --warnings, or open {workspace} in Xcode for details')
        finally:
            restore_plists(repo)
        log(f'archived {archive_path}', style='ok')

    # -- upload

    if not upload:
        return
    if not archive_path:
        archives = all_archives(scheme)
        if not archives:
            raise Stop('no archive to upload', 're-run without --no-archive')
        archive_path = Path(archives[0])

    team = xcconfig(repo).get('DEVELOPMENT_TEAM')
    if not team:
        raise Stop('DEVELOPMENT_TEAM not set', 'set it in Config/User.xcconfig')
    key = asc_key()
    if not key:
        raise Stop('no App Store Connect API key', 'set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, '
                   'then check it with: Fork/release.py asc-check')
    key_id, issuer_id, key_path = key

    if not confirm(f'upload {archive_path.name} to App Store Connect (team {team})', yes):
        return

    with tempfile.TemporaryDirectory() as tmp:
        options = Path(tmp) / 'ExportOptions.plist'
        options.write_bytes(plistlib.dumps({
            'method': 'app-store-connect',
            'destination': 'export',
            'teamID': team,
            'signingStyle': 'automatic',
            'manageAppVersionAndBuildNumber': False,
            'uploadSymbols': True,
        }))
        try:
            xcodebuild('-exportArchive', '-archivePath', archive_path, '-exportOptionsPlist', options,
                       '-exportPath', Path(tmp) / 'export', '-allowProvisioningUpdates', *asc_auth_args(),
                       warnings=warnings)
            ipas = glob.glob(str(Path(tmp) / 'export' / '*.ipa'))
            if not ipas:
                raise Stop(f'export of {archive_path.name} produced no .ipa')
            run('xcrun', 'altool', '--upload-app', '-f', ipas[0], '-t', 'ios',
                '--apiKey', key_id, '--apiIssuer', issuer_id, '--p8-file-path', key_path)
        except subprocess.CalledProcessError:
            raise Stop(f'upload of {archive_path.name} failed', 'see the output above; the archive is kept, '
                       're-run with --no-update --no-clean --no-archive to retry the upload')

    log(f'uploaded {archive_path.name}; it shows in TestFlight once App Store Connect finishes processing',
        style='ok')

    # -- what to test

    info = archive_info(archive_path)
    tag = f"{testflight_tag_prefix}{info['version']}-{info['build']}"
    if not notes:
        notes = testflight_notes(repo, info['commit'], tag) if info['commit'] else 'Updated from upstream Signal.'
    if info['commit']:
        # marks where the next build's "upstream changes since" starts
        git(repo, 'tag', '-f', tag, info['commit'])
    log(f"What to Test for {info['version']} ({info['build']}):\n{notes}")
    retry = f"Fork/release.py notes {info['version']} {info['build']}"
    try:
        if asc_set_whats_new(info['bundle_id'], info['version'], info['build'], notes, wait=notes_wait):
            log('set What to Test', style='ok')
        else:
            log(f"App Store Connect doesn't list the build yet; set the notes later with: {retry}", style='warn')
    except Stop as e:
        log(f"warning: couldn't set What to Test ({e}); retry with: {retry}", style='warn')


def notes_command(repo, version, build, notes=None, show=False, wait=0, scheme='Signal'):
    '''set (or with show, just print) a TestFlight build's What to Test text'''
    _, info = find_archive(scheme, version, build)
    tag = f'{testflight_tag_prefix}{version}-{build}'
    if not notes:
        if not info or not info['commit']:
            raise Stop(f'no {scheme} {version} ({build}) archive with a source commit', 'pass --notes')
        notes = testflight_notes(repo, info['commit'], tag)
    bundle_id = info['bundle_id'] if info else app_bundle_id(repo)

    log(f'What to Test for {version} ({build}):\n{notes}')
    if show:
        return
    if info and info['commit']:
        git(repo, 'tag', '-f', tag, info['commit'])
    if asc_set_whats_new(bundle_id, version, build, notes, wait=wait):
        log(f'set What to Test for {version} ({build})', style='ok')
    else:
        log(f"App Store Connect doesn't list {version} ({build}) yet; "
            f're-run later: Fork/release.py notes {version} {build}', style='warn')


def asc_check(repo):
    '''check the API key works and the app record for the bundle id exists'''
    apps = asc_get('apps', limit=200, **{'fields[apps]': 'name,bundleId'}).get('data', [])
    log(f'api key ok: {len(apps)} app{"s" if len(apps) != 1 else ""} visible', style='ok')
    bundle_id = app_bundle_id(repo)
    match = [aa for aa in apps if aa['attributes'].get('bundleId') == bundle_id]
    if match:
        log(f"app record ok: {match[0]['attributes'].get('name')} ({bundle_id})", style='ok')
    else:
        log(f'missing app record for {bundle_id}: create it in App Store Connect > Apps > + > New App', style='warn')


# ---------------------------------------------------------------------
# self-test: the local pieces against a throwaway repo (no network, no xcodebuild)

def self_test():
    global archives_dir
    saved_env = {kk: os.environ.pop(kk) for kk in list(os.environ) if kk.startswith('GIT_') or kk.startswith('ASC_')}
    saved_archives = archives_dir
    try:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp).resolve()
            _test_repo(tmp)
            _test_update(tmp)
            _test_archive_info(tmp)
            _test_asc_token(tmp)
    finally:
        archives_dir = saved_archives
        os.environ.update(saved_env)
    log('self-test ok', style='ok')


def _init_repo(path, branch='main'):
    path.mkdir(parents=True)
    git(path, 'init', '-q', '-b', branch)
    for kk, vv in (('user.name', 'test'), ('user.email', 'test@example.com'), ('commit.gpgsign', 'false'),
                   ('tag.gpgsign', 'false')):
        git(path, 'config', kk, vv)


def _commit(repo, message, **files):
    for name, text in files.items():
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(text)
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '--allow-empty', '-m', message)
    return git(repo, 'rev-parse', 'HEAD')


def _test_repo(tmp):
    repo = tmp / 'SignalMSP'
    _init_repo(repo)

    # upstream history, with a previous testflight build part way along
    plist = plistlib.dumps({'CFBundleShortVersionString': '8.34', 'CFBundleVersion': '0'}).decode()
    _commit(repo, 'Initial', **{rel: plist for rel in info_plists},
            **{'fastlane/metadata/en-US/release_notes.txt': 'Old notes.\n',
               'Config/Project.xcconfig': 'DEVELOPMENT_TEAM = UPSTREAM1\nSIGNAL_BUNDLEID_PREFIX = org.example\n',
               'Config/User.xcconfig': '// personal\nDEVELOPMENT_TEAM = MYTEAM123 // mine\n'})
    git(repo, 'tag', 'testflight/8.33-4')
    _commit(repo, 'Fix voice note waveform')
    _commit(repo, 'Update translations')
    _commit(repo, 'Update release notes', **{'fastlane/metadata/en-US/release_notes.txt': 'Sticker improvements.\n'})
    _commit(repo, 'Use Xcode 27 in Xcode Cloud')
    for nn in range(45):
        _commit(repo, f'Upstream change {nn}')
    git(repo, 'update-ref', 'refs/remotes/upstream/main', 'HEAD')

    # the fork's own commits on top
    _commit(repo, 'Add call mute shortcuts')
    head = _commit(repo, 'Personal signing and app icon')

    # xcconfig: User overrides Project, trailing comments dropped
    conf = xcconfig(repo)
    assert conf['DEVELOPMENT_TEAM'] == 'MYTEAM123' and conf['SIGNAL_BUNDLEID_PREFIX'] == 'org.example', conf
    assert app_bundle_id(repo) == 'org.example.signal'

    # notes: release notes, fork commits, upstream since the previous tag minus housekeeping
    notes = testflight_notes(repo, head, tag='testflight/8.34-1')
    assert notes.startswith('Signal release notes:\nSticker improvements.'), notes
    assert 'In this fork:\n• Add call mute shortcuts\n• Personal signing and app icon' in notes, notes
    # newest first; 46 upstream changes once housekeeping is dropped (49 with it), 40 shown
    assert 'Upstream changes since 8.33-4:\n• Upstream change 44\n' in notes, notes
    assert not any(nn in notes for nn in ('Update translations', 'Update release notes', 'Use Xcode 27')), notes
    assert notes.endswith('…and 6 more'), notes
    assert len(notes) <= testflight_notes_limit

    # the build's own tag isn't "previous"
    git(repo, 'tag', 'testflight/8.34-1', head)
    assert 'since 8.33-4' in testflight_notes(repo, head, tag='testflight/8.34-1')
    git(repo, 'tag', '-d', 'testflight/8.34-1')

    # without a previous tag there's no upstream section
    git(repo, 'tag', '-d', 'testflight/8.33-4')
    assert 'Upstream changes' not in testflight_notes(repo, head)

    # restoring plists: stamp and build number only
    stamped = repo / info_plists[0]
    info = plistlib.loads(stamped.read_bytes())
    info.update(BuildDetails={'SignalCommit': head}, CFBundleVersion='12')
    stamped.write_bytes(plistlib.dumps(info))
    restore_plists(repo)
    assert not git(repo, 'status', '--porcelain')

    info['CFBundleDisplayName'] = 'Mine'
    stamped.write_bytes(plistlib.dumps(info))
    restore_plists(repo)
    assert git(repo, 'status', '--porcelain'), 'a plist with other edits should be left alone'
    git(repo, 'checkout', '--', info_plists[0])

    if sys.platform == 'darwin':  # PlistBuddy
        set_build_number(repo, 7)
        assert all(plistlib.loads((repo / rel).read_bytes())['CFBundleVersion'] == '7' for rel in info_plists)
        restore_plists(repo)
        assert not git(repo, 'status', '--porcelain')


def _test_update(tmp):
    '''the stack (app-intents, mute-triggers, personal) rebases onto upstream in one go,
    keeping each commit, and gets pushed'''
    upstream, origin, repo = tmp / 'upstream', tmp / 'origin.git', tmp / 'fork'
    _init_repo(upstream)
    _commit(upstream, 'Initial', **{'README.md': 'signal\n'})

    git(tmp, 'clone', '-q', '--bare', str(upstream), str(origin))
    git(tmp, 'clone', '-q', str(origin), str(repo))
    for kk, vv in (('user.name', 'test'), ('user.email', 'test@example.com'), ('commit.gpgsign', 'false')):
        git(repo, 'config', kk, vv)
    git(repo, 'remote', 'add', 'upstream', str(upstream))
    git(repo, 'fetch', '-q', 'upstream')

    # a side branch for a separate upstream PR isn't part of the stack
    git(repo, 'checkout', '-q', '-b', 'regid-warnings')
    _commit(repo, 'Log failures as warnings', **{'a.txt': 'a\n'})
    git(repo, 'checkout', '-q', '-b', 'app-intents', 'main')
    _commit(repo, 'Add call mute shortcuts', **{'b.txt': 'b\n'})
    git(repo, 'checkout', '-q', '-b', 'mute-triggers')
    _commit(repo, 'Log failures as warnings', **{'a.txt': 'a\n'})
    git(repo, 'checkout', '-q', '-b', 'personal')
    _commit(repo, 'Personal signing', **{'c.txt': 'c\n'})
    git(repo, 'push', '-q', 'origin', 'app-intents', 'mute-triggers', 'personal')

    assert stack_branches(repo, 'personal') == ['app-intents', 'mute-triggers']
    assert left_behind_branches(repo, 'personal') == []

    _commit(upstream, 'Upstream change', **{'d.txt': 'd\n'})
    update(repo, 'personal', yes=True, make=None)

    assert is_ancestor(repo, 'upstream/main', 'app-intents')
    assert is_ancestor(repo, 'app-intents', 'mute-triggers') and is_ancestor(repo, 'mute-triggers', 'personal')
    assert git_lines(repo, 'log', '--format=%s', 'upstream/main..app-intents') == ['Add call mute shortcuts']
    assert git_lines(repo, 'log', '--format=%s', 'app-intents..mute-triggers') == ['Log failures as warnings']
    assert git_lines(repo, 'log', '--format=%s', 'mute-triggers..personal') == ['Personal signing']
    for bb in ('app-intents', 'mute-triggers', 'personal'):
        assert git(repo, 'rev-parse', bb) == git(origin, 'rev-parse', bb), f'{bb} not pushed'
    assert not is_ancestor(repo, 'upstream/main', 'regid-warnings'), 'side branches are left alone'

    # a commit on a lower branch that personal lacks stops the update
    git(repo, 'checkout', '-q', 'app-intents')
    _commit(repo, 'Forgot to rebase personal')
    git(repo, 'checkout', '-q', 'personal')
    assert left_behind_branches(repo, 'personal') == ['app-intents']
    try:
        update(repo, 'personal', yes=True, make=None)
        raise AssertionError('expected Stop')
    except Stop as e:
        assert "'app-intents' has commits" in str(e), e


def _test_archive_info(tmp):
    global archives_dir
    archives_dir = tmp / 'Archives'
    app = archives_dir / '2026-10-23' / 'Signal 8.34 (3) 10.00.00.xcarchive' / 'Products' / 'Applications' / 'Signal.app'
    app.mkdir(parents=True)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleShortVersionString': '8.34', 'CFBundleVersion': '3', 'CFBundleIdentifier': 'org.example.signal',
        'BuildDetails': {'SignalCommit': 'abc123 Personal signing and app icon'}}))
    info = archive_info(app.parents[2])
    assert info == {'version': '8.34', 'build': '3', 'bundle_id': 'org.example.signal', 'commit': 'abc123'}, info
    path, found = find_archive('Signal', '8.34', 3)
    assert path == app.parents[2] and found == info
    assert find_archive('Signal', '8.34', 4) == (None, None)


def _test_asc_token(tmp):
    # sign with a throwaway P-256 key and check the signature with openssl
    key = tmp / 'AuthKey_TEST.p8'
    run('openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', tmp / 'ec.pem', capture=True, quiet=True)
    run('openssl', 'pkcs8', '-topk8', '-nocrypt', '-in', tmp / 'ec.pem', '-out', key, capture=True, quiet=True)
    run('openssl', 'ec', '-in', tmp / 'ec.pem', '-pubout', '-out', tmp / 'pub.pem', capture=True, quiet=True)
    os.environ.update(ASC_KEY_ID='TESTKEY', ASC_ISSUER_ID='issuer-uuid', ASC_KEY_PATH=str(key))

    def unb64(part):
        return base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))

    def der_int(value):
        body = value.to_bytes(32, 'big').lstrip(b'\0') or b'\0'
        if body[0] & 0x80:
            body = b'\0' + body
        return b'\x02' + bytes([len(body)]) + body

    for _ in range(5):  # r/s with a high bit set encode as 33 DER bytes; cover a few signatures
        header, claims, signature = asc_token().split('.')
        assert json.loads(unb64(header)) == {'alg': 'ES256', 'kid': 'TESTKEY', 'typ': 'JWT'}
        assert json.loads(unb64(claims))['iss'] == 'issuer-uuid'
        raw = unb64(signature)
        assert len(raw) == 64

        ints = der_int(int.from_bytes(raw[:32], 'big')) + der_int(int.from_bytes(raw[32:], 'big'))
        (tmp / 'sig.der').write_bytes(b'\x30' + bytes([len(ints)]) + ints)
        verified = run('openssl', 'dgst', '-sha256', '-verify', tmp / 'pub.pem', '-signature', tmp / 'sig.der',
                       input=f'{header}.{claims}'.encode(), capture=True, check=False, quiet=True)
        assert verified.returncode == 0, verified.stdout + verified.stderr

    for kk in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH'):
        os.environ.pop(kk)


# ---------------------------------------------------------------------

def main(argv=None):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--path', type=Path, default=repo_default, help='SignalMSP checkout (default: this one)')
    common.add_argument('--scheme', default='Signal')

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command')

    rel = sub.add_parser('release', parents=[common], help='update, build and upload (the default)')
    rel.add_argument('--branch', default='personal', help='branch to build (default: personal)')
    rel.add_argument('--no-update', '--no-merge', dest='update', action='store_false',
                     help='skip rebasing onto upstream')
    rel.add_argument('--no-clean', dest='clean', action='store_false')
    rel.add_argument('--no-archive', dest='archive', action='store_false', help='upload the newest archive')
    rel.add_argument('--no-upload', dest='upload', action='store_false')
    rel.add_argument('--derived-data', action='store_true', help="also delete Signal's DerivedData when cleaning")
    rel.add_argument('--yes', '-y', action='store_true',
                     help="don't ask before pushing or uploading (still stops on conflicts or failures)")
    rel.add_argument('--warnings', action='store_true', help='show build warnings (mostly third-party Pods)')
    rel.add_argument('--notes', help='What to Test text, instead of generating it')
    rel.add_argument('--notes-wait', type=int, default=30,
                     help='minutes to wait for App Store Connect to list the build before setting notes')

    nts = sub.add_parser('notes', parents=[common], help="set a TestFlight build's What to Test text")
    nts.add_argument('version', help='marketing version, e.g. 8.34')
    nts.add_argument('build', help='build number')
    nts.add_argument('--notes', help='text to use instead of the generated notes')
    nts.add_argument('--show', action='store_true', help='print the notes without setting them')
    nts.add_argument('--wait', type=int, default=0, help='minutes to wait for App Store Connect to list the build')

    sub.add_parser('asc-check', parents=[common], help='check the App Store Connect API key and app record')
    sub.add_parser('self-test', parents=[common], help='offline tests of the local pieces')

    argv = sys.argv[1:] if argv is None else argv
    commands = ('release', 'notes', 'asc-check', 'self-test', '-h', '--help')
    if not argv or argv[0] not in commands:
        argv = ['release', *argv]  # release is the default command
    args = parser.parse_args(argv)
    repo = args.path.expanduser().resolve()

    try:
        if args.command == 'release':
            release(repo, branch=args.branch, scheme=args.scheme, do_update=args.update, clean=args.clean,
                    archive=args.archive, upload=args.upload, derived_data=args.derived_data, yes=args.yes,
                    warnings=args.warnings, notes=args.notes, notes_wait=args.notes_wait)
        elif args.command == 'notes':
            notes_command(repo, args.version, args.build, notes=args.notes, show=args.show, wait=args.wait,
                          scheme=args.scheme)
        elif args.command == 'asc-check':
            asc_check(repo)
        elif args.command == 'self-test':
            self_test()
    except Stop as e:
        log(f'stopped: {e}', style='error')
        for step in e.steps:
            log(f'  {step}', style='warn')
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == '__main__':
    sys.exit(main())

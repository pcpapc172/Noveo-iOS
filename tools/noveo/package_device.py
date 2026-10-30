#!/usr/bin/env python3
"""Package only a verified arm64 iPhoneOS archive, never an arm64 simulator build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile


def validate_device(info, build_info):
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Expected an iPhoneOS device app, not a simulator app')
    if info.get('CFBundleIdentifier') != 'ir.noveo.ios':
        raise ValueError('Unexpected bundle identity')
    platforms = re.findall(r'^\s*platform\s+(\S+)', build_info, re.MULTILINE)
    architectures = re.findall(r'^\s*(?:architecture|arch)\s+(\S+)', build_info, re.MULTILINE)
    if not platforms or any(p != 'IOS' for p in platforms):
        raise ValueError('Mach-O must target IOS, never IOSSIMULATOR or macOS')
    if not architectures or any(a != 'arm64' for a in architectures):
        raise ValueError('Expected an arm64 device executable')


def link_archive(source, destination):
    """Expose both extensions without allocating another copy of the device archive."""
    if destination.exists():
        if destination.samefile(source):
            return
        raise FileExistsError("Refusing to replace unrelated artifact: " + str(destination))
    # Fail rather than falling back to a full copy if the output is on another filesystem.
    os.link(source.resolve(), destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError('Corrupt archive member: ' + bad)
        plists = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
        if len(plists) != 1:
            raise ValueError('Expected a single top-level app')
        info = plistlib.loads(archive.read(plists[0]))
        executable = info['CFBundleExecutable']
        if '/' in executable or executable in ('', '.', '..'):
            raise ValueError('Invalid executable name')
        member = plists[0].rsplit('/', 1)[0] + '/' + executable
        with tempfile.TemporaryDirectory(prefix='noveo-ipa-check-') as stage:
            binary = Path(stage) / 'executable'
            with archive.open(member) as source, binary.open("wb") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)
            build_info = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
            # vtool prints architecture on the filename line, not the load-command fields.
            architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
            build_info += ''.join('\narchitecture ' + a for a in architectures)
            validate_device(info, build_info)
    args.output.mkdir(parents=True, exist_ok=True)
    for suffix in ('ipa', 'tipa'):
        link_archive(args.archive, args.output / ('Noveo-iOS-test.' + suffix))
    with args.archive.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    (args.output / 'SHA256SUMS').write_text(''.join(digest + '  Noveo-iOS-test.' + s + '\n' for s in ('ipa', 'tipa')))
    (args.output / 'build-info.json').write_text(json.dumps({
        'bundle_id': info['CFBundleIdentifier'], 'version': info.get('CFBundleShortVersionString'),
        'build': info.get('CFBundleVersion'), 'minimum_ios': info.get('MinimumOSVersion'),
        'platform': 'iPhoneOS', 'architecture': 'arm64',
        'signing': 'Unprovisioned test build; IPA requires sideload signing, TIPA requires compatible TrollStore',
    }, indent=2))
    (args.output / 'README.txt').write_text(
        'Noveo iOS development test build (arm64 iPhone/iPad).\n'
        'IPA: sign/install with your sideloading tool. No distribution certificate is included.\n'
        'TIPA: the same app archive with the TrollStore extension; requires a compatible TrollStore device.\n'
        'This port is incomplete: the native login/chats are not yet Noveo-backed.\n'
        'This is not an App Store/TestFlight release and does not enable APNs.\n')


if __name__ == '__main__':
    main()

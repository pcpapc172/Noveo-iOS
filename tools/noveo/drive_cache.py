#!/usr/bin/env python3
"""Stream Bazel cache snapshots through rclone; never stage a second archive on disk."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


def rclone(*args, **kwargs):
    return subprocess.run(['rclone', *args], check=True, **kwargs)


def manifest(remote):
    result = subprocess.run(['rclone', 'cat', remote + '/latest.json'], capture_output=True, text=True)
    if result.returncode:
        return None
    saved = json.loads(result.stdout)
    if not re.fullmatch(r'cache-[0-9]+-[0-9]+\.tar\.zst', saved.get('file', '')):
        raise ValueError('Invalid cache snapshot filename')
    return saved


def pipeline(commands):
    processes = []
    previous = None
    try:
        for command in commands:
            process = subprocess.Popen(command, stdin=previous.stdout if previous else None,
                                       stdout=subprocess.PIPE if len(processes) < len(commands) - 1 else None)
            if previous:
                previous.stdout.close()
            processes.append(process)
            previous = process
        failures = [p.wait() for p in reversed(processes)]
        if any(failures):
            raise RuntimeError('Cache streaming pipeline failed: ' + str(failures))
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()


def restore(cache, remote):
    saved = manifest(remote)
    if not saved:
        print('No Drive snapshot yet; this build will populate it.')
        return False
    # Restore into a staging directory so a failed download cannot damage the previous cache.
    cache.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.noveo-cache-restore-', dir=cache.parent))
    try:
        pipeline([['rclone', 'cat', remote + '/' + saved['file']], ['zstd', '-d', '-q', '-c'],
                  ['tar', '-xf', '-', '-C', str(staging)]])
        if cache.exists():
            shutil.rmtree(cache)
        staging.rename(cache)
        print('Restored complete Drive cache snapshot: ' + saved['file'])
        return True
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def save(cache, remote):
    if not cache.is_dir() or not any(cache.iterdir()):
        print('No Bazel disk cache to upload.')
        return
    name = 'cache-' + str(time.time_ns()) + '-' + str(os.getpid()) + '.tar.zst'
    rclone('mkdir', remote)
    pipeline([['tar', '-cf', '-', '-C', str(cache), '.'], ['zstd', '-q', '-T2', '-3', '-c'],
              ['rclone', 'rcat', remote + '/' + name]])
    # Publish the pointer only after every producer and upload succeeds.
    rclone('rcat', remote + '/latest.json', input=json.dumps({'file': name}).encode())
    listing = rclone('lsjson', remote, '--files-only', capture_output=True, text=True)
    snapshots = sorted((item['Name'] for item in json.loads(listing.stdout)
                        if re.fullmatch(r'cache-[0-9]+-[0-9]+\.tar\.zst', item['Name'])), reverse=True)
    for stale in snapshots[2:]:
        rclone('deletefile', remote + '/' + stale)
    print('Saved Drive cache snapshot; retained the newest two.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['restore', 'save'])
    parser.add_argument('cache', type=Path)
    parser.add_argument('remote')
    args = parser.parse_args()
    if args.operation == 'restore':
        hit = restore(args.cache.expanduser(), args.remote.rstrip('/'))
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write('hit=' + str(hit).lower() + '\n')
    else:
        save(args.cache.expanduser(), args.remote.rstrip('/'))


if __name__ == '__main__':
    main()

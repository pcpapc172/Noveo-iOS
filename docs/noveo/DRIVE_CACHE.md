# Google Drive build cache

The device workflow uses a dedicated `noveocache` rclone remote when the repository secret
`NOVEO_RCLONE_CONFIG` exists. Otherwise it retains GitHub cache support. On the first Drive run,
GitHub's existing cache seeds the Drive snapshot. Cache namespaces include the pinned toolchain
and dependency metadata. The running build is not cancelled or restarted by this change.

The Drive configuration must use `type = drive` and the `drive.file` scope (only files created
or opened by this application), rather than access to all personal files. Authorize locally using
rclone and save only this dedicated remote's configuration as the GitHub repository secret.
Do not paste the token into a chat, commit it, or add it to workflow YAML.

An authorized local config can be installed directly into GitHub Secrets with:

```
gh secret set NOVEO_RCLONE_CONFIG -R pcpapc172/Noveo-iOS < ~/.config/rclone/noveo-ci-cache.conf
```

Snapshots stream `tar | zstd | rclone rcat` into
`noveocache:noveo-build-cache/ios-device-arm64/<toolchain-hash>/`.
No temporary compressed archive is written on the runner. The latest pointer changes only after
all upload pipeline stages succeed. The two newest snapshots are kept; pruning touches only
snapshot files with this helper's generated filename pattern in that cache namespace.
The previous 5 GB Bazel disk cache cap is omitted while Drive is enabled. Runner disk capacity
still limits how much can be held locally, and Drive transfer time still contributes to total CI time.
Credentials exist only in a mode-0600 temporary runner config and are removed in a final step.

Local verification used rclone's local backend: compressed streaming upload/download round trip,
retention of exactly two snapshots, and preservation of the existing pointer for an empty cache.
Google authorization and a live Drive upload must still be verified before claiming Drive is active.

To populate Drive from a completely cold device build, dispatch build.yml with cold_build=true. Both Drive and GitHub cache restores are skipped, a configured Drive secret is required, and the run gets its own concurrency group so it can execute beside a normal device build. Cache saving and artifact upload still run normally; existing builds are not cancelled.

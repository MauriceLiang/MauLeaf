# Vendored batt dependency

- `batt-version` pins upstream `v0.8.0`.
- GitHub Actions verifies the official ARM64 archive's SHA-256 before bundling batt in the supported Apple Silicon release.
- The Intel experimental preview contains no batt or uninstaller, exposes battery information only, and does not support charging control.
- The GPL-2.0 license and corresponding upstream source are distributed with the application and GitHub Release.

Upstream: https://github.com/charlie0129/batt

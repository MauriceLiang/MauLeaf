# Vendored batt dependency

- `batt-version` pins the upstream release used for builds (`v0.8.0`).
- `build.command` downloads the official Apple Silicon release asset and verifies its SHA-256 digest when the release metadata publishes one.
- The resulting binary is copied into both app bundles so end users do not need to download it at runtime.
- The upstream license is bundled in the app resources.

Upstream project: https://github.com/charlie0129/batt

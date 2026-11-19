# MauLeaf Unplugged Restore Probe

**Independent hardware experiment — NOT a production charging controller.**

This one-shot macOS command-line tool tests a single, necessary prerequisite for safe complete uninstallation **without an AC adapter**: can the validated M1 Pro safely deactivate an **already-active** firmware-managed charging limit by writing **only `bfF0 = 0x00` while running on battery power**, and read back that value?

It does **not** prove that all original firmware settings have been restored, that the battery will charge past its old upper limit after reconnection, or that an app may safely remove its helper and snapshot. These must be tested separately.

## Strict scope

Target for the experimental write:

- Apple Silicon `arm64`
- `MacBookPro18,1`
- macOS **15**
- System firmware exactly `mBoot-20457.41.3`
- A valid, root-owned MauLeaf original-state snapshot at `/Library/Application Support/MauLeaf/original-firmware-state.json`, whose original `bfF0` was **0x00**
- The current `bfF0` must be **0x02**
- No running MauLeaf GUI or other recognized charging-controller process
- IOKit explicitly reports `ExternalConnected = false` **and** `pmset -g batt` explicitly reports `Battery Power`
- Battery percentage is readable and at least **30%**, and the battery is not charging
- Root privileges plus interactive typed confirmation for the one-byte write

Any failed or unknown guard blocks the test. The tool cannot install a daemon, create a charging limit, touch adapter/discharge keys, change `bfD0`/`bfE0`, turn `bfF0` back on, or delete recovery data. It never alters the production AC-power requirement in MauLeaf.

**Important:** This test uses a real SMC write, which is not risk-free. Do not run it on unverified hardware or firmware, with a nearly depleted battery, or while another charging application is active.

## Download and run

Download the `MauLeafUnpluggedRestoreProbe-macos15-arm64` artifact from a successful [Build MauLeaf Unplugged Restore Probe workflow](../../.github/workflows/build-unplugged-restore-probe.yml). This artifact is **not** an ordinary MauLeaf release and must not be distributed as a user charging feature.

For a first read-only check (without root when possible):

```bash
chmod +x ./MauLeafUnpluggedRestoreProbe
./MauLeafUnpluggedRestoreProbe status
```

If AppleSMC refuses read access, `sudo ./MauLeafUnpluggedRestoreProbe status` is also **read-only**.

### Prepare the test

1. **While connected to AC**, use MauLeaf Preview 7 to enable a charging limit (for example 80%) and confirm that the firmware currently reports `bfF0=0x02` and a valid **original-state snapshot** exists. Do not use a legacy Preview 4 activation without its original snapshot.
2. **Unplug** the power adapter (including USB-C power). Ensure the battery is at least **30%**.
3. **Quit MauLeaf normally while still unplugged.** Preview 7 should persist a deferred restore request; it must not erase the original snapshot while unplugged. Do not force-remove the existing recovery helper.
4. Run `sudo ./MauLeafUnpluggedRestoreProbe status`. Check that `External power: false`, `pmset battery: true`, `bfF0=0x02`, the hardware identity matches, and the original snapshot is valid.
5. If those conditions hold, run the experimental test below. The tool repeats its checks and refuses if the state changed.

```bash
sudo ./MauLeafUnpluggedRestoreProbe test-unplugged-deactivation
```

It prints the exact planned mutation and requires typing:

```text
UNPLUGGED BFf0 OFF MacBookPro18,1
```

The tool writes only `bfF0=0x00`, then reads back **all three firmware keys**; the two thresholds must remain unchanged. It tries no more than three times. If any check fails, it reports the failure; **it never reactivates the limit as a rollback**.

### Preserve the evidence

Run the command from the extracted artifact folder and capture its full terminal output. For example:

```bash
set -o pipefail
sudo ./MauLeafUnpluggedRestoreProbe test-unplugged-deactivation 2>&1 | tee ~/Desktop/MauLeaf-unplugged-restore-test.txt
```

Do **not** use that command until the read-only status matches every requirement. The log contains your device model, firmware identifier, registers, and battery status: review it before sharing publicly.

### Verify physical charging separately

1. After the test, reconnect the charger. Keep the existing MauLeaf Helper and original snapshot so the queued **exact original-state restoration** can finish.
2. Check `sudo ./MauLeafUnpluggedRestoreProbe status` after AC reconnects; `bfF0` should remain inactive and the original thresholds should be restored by MauLeaf's helper.
3. Observe actual battery charging behavior through the former upper-limit threshold. **Register readback alone does not prove the battery has resumed charging.** macOS Optimized Battery Charging, temperature, charge tapering, and the battery's current percentage can affect observations.
4. Only after these results should the main MauLeaf project consider a separately validated **offline full original-state restoration** and eventually **offline complete uninstall**.

## Phase 3: battery-only FULL original-state restoration (experimental)

This is a **new command**, distinct from the already-verified `test-unplugged-deactivation`. It performs three read-back-verified writes while running entirely on battery power: first `bfF0=0x00`, then the two **original** thresholds read from MauLeaf's root-owned snapshot. The order is chosen to keep the intermediate lower/upper range valid. It does **not** reinstall or remove anything.

### Prepare a test that can actually verify both threshold writes

Your previous successful deactivation was followed by AC-powered background recovery. That intentionally removed the snapshot and left `bfF0=0x00, bfD0=80, bfE0=78`. **The old snapshot cannot be reused.**

1. Install/retain **MauLeaf v0.8.0-preview.7** for Mac Apple Silicon. Older Preview 4 may not save a proper original snapshot.
2. Plug in AC, launch MauLeaf Preview 7, and explicitly enable the limit at **85%**. Its original snapshot should record the current disabled values `0x00, 80%, 78%`, while the active limit becomes `0x02, 85%, 83%`. This gives the test something real to restore. (If your original values differ, the tool will display them instead.)
3. With AC still connected, run `sudo ./MauLeafUnpluggedRestoreProbe status`. Check that `bfF0=0x02` and the original snapshot exists and matches the machine.
4. Unplug ALL charging adapters, confirm battery percentage >=30%, quit MauLeaf normally (do not force quit or delete its helper), then run the same read-only `status`. The snapshot must remain valid, `pmset battery=true`, `External power=false`, `MauLeaf running=false`, and `bfF0=0x02`.
5. Perform the single one-shot test:

```bash
sudo ./MauLeafUnpluggedRestoreProbe test-unplugged-full-restore
```

At the interactive prompt, type exactly:

```text
UNPLUGGED FULL RESTORE MacBookPro18,1
```

The CLI prints the exact before/original values before accepting confirmation. It also requires BOTH upper/lower values to differ, so the test actually covers two threshold writes; otherwise it refuses.

**On PASS:** all three registers were restored and verified while running on battery power. Preserve the root-owned snapshot and existing Helper; reconnect AC and let Preview 7 finish its normal restoration/cleanup. Verify actual battery charging afterwards. This result does not demonstrate completely removing the Helper while unplugged.

**On FAILED:** do not rerun blindly, force-remove any helper, delete the snapshot, or try another charging-control tool. Save the output, reconnect AC to let the previously queued standard restore run, and check the final state.

## Phase 4: complete offline uninstall — NOT YET IMPLEMENTED

Do **not** interpret Phase 3's success as permission to remove the Helper and snapshot. Preview 7's default uninstaller currently queues an AC-powered background restore when the Mac is unplugged, even if the test previously showed it can deactivate `bfF0`. An immediate, fully verified offline uninstall requires a future production change and separate hardware acceptance tests.

Existing **safe but deferred** Preview 7 uninstaller (run while the app is fully quit):

```bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
```

When unplugged, this may **retain** its root-owned recovery Helper until AC is connected and firmware recovery is verified. It is NOT an immediate complete removal. Never use `--force-remove-without-restore` to bypass that protection.

## What this cannot establish

- If `bfF0` is already **0x00**, no write is made, and the test does not claim to have proven offline SMC-write capability.
- If the snapshot is missing or was originally active, the tool refuses to write; it cannot reconstruct unknown pre-MauLeaf thresholds.
- If the tool fails to verify the write, **do not remove the original snapshot or Helper**. Preserve the log and use the standard MauLeaf recovery path after reconnecting power.
- A forced deletion of all components while the firmware limit is still enabled can leave charging restricted. The experiment is not permission to use `--force-remove-without-restore` in production.
- The tool does not measure charge current, prove charging above 80%, or run on the user's physical Mac from GitHub Actions. GitHub Actions tests use a **fake SMC transport** and never write to real hardware.

## Build from source

From the MauLeaf repository root, on macOS with Xcode Command Line Tools:

```bash
swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  -framework IOKit \
  Sources/FirmwareLimitCore.swift \
  Sources/FirmwareLimitReconciliation.swift \
  Sources/FirmwareLimitSMCTransport.swift \
  Sources/SystemFirmwareReader.swift \
  Sources/FirmwareLimitRuntime.swift \
  Sources/BatteryStatusReader.swift \
  Tools/MauLeafUnpluggedRestoreProbe/UnpluggedRestorePolicy.swift \
  Tools/MauLeafUnpluggedRestoreProbe/MauLeafUnpluggedRestoreProbe.swift \
  -o MauLeafUnpluggedRestoreProbe
```

No batt binary, third-party framework, login item, or daemon is needed. The GitHub Actions artifact also contains the relevant source files and SHA-256 checksum for auditing.

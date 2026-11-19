# MauLeaf Firmware Limit Write Check

A one-shot, narrowly scoped diagnostic for the bfF0 / bfD0 / bfE0 firmware charge-limit keys detected on the user's MacBookPro18,1.

## Important: two modes

- status is read-only and is the default.
- write-check requires sudo, AC power, a closed MauLeaf app, no running batt process, an exact model/firmware match, and an interactive typed confirmation.

The write check is intentionally a no-op against the current configuration. It only runs while bfF0 is 0x00 (firmware limit disabled), then writes the values it just read back to the same keys:

- bfF0 = 0x00 — remains disabled
- bfD0 = current upper value — unchanged
- bfE0 = current lower value — unchanged

Each write is read back and verified. The program never writes bfF0 = 0x02, never activates a charging limit, never changes adapter-input keys, and never installs a daemon or login item. If verification fails, it attempts to rewrite and verify the exact pre-test values.

This checks whether the current process can write and read back the three key registers. It does not prove that an enabled firmware limit will enforce charging behavior. That is a separate hardware test and will require a separate explicit step.

## Supported target

Writes are deliberately restricted to the exact machine reported by the owner:

- Model: MacBookPro18,1
- System firmware: mBoot-20457.41.3
- macOS major version: 15
- Architecture: arm64

A different model, firmware build, or macOS major version is refused. Do not remove this gate just to make the tool run on another Mac.

## Run

First inspect without administrator privileges:

~~~bash
./MauLeafFirmwareLimitWriteCheck status
~~~

Before the write check:

1. Connect the MacBook to its power adapter.
2. Quit MauLeaf completely.
3. Stop any other battery-control process, including batt.
4. Confirm that the read-only status shows bfF0 = 0x00.

Then run:

~~~bash
sudo ./MauLeafFirmwareLimitWriteCheck write-check
~~~

Read the warning and type exactly:

~~~text
WRITE-CHECK MacBookPro18,1
~~~

If the phrase does not match, the program exits without writing.

## Safety boundaries

- No SMC writes occur in status.
- write-check writes only the three firmware charge-limit keys and only their already-existing values.
- The firmware activation byte must be off before the write check.
- The program refuses to run if the battery-control app or a batt process is active.
- No adapter-cut or discharge key is accessed.
- No persistent configuration, daemon, login item, or app preference is created.
- The tool is not a production controller and must not be bundled into MauLeaf.app.

A successful result confirms SMC write access and read-back for these key shapes only. It is not evidence that bfF0 = 0x02 works or that the firmware enforces the limit. Do not infer that from a successful no-op write check.

## Build locally

~~~bash
swiftc -O -target arm64-apple-macos15.0 \
  -framework IOKit \
  Tools/MauLeafFirmwareLimitWriteCheck/FirmwareLimitPolicy.swift \
  Tools/MauLeafFirmwareLimitWriteCheck/MauLeafFirmwareLimitWriteCheck.swift \
  -o MauLeafFirmwareLimitWriteCheck
~~~

The GitHub Actions workflow builds the arm64 binary on a macOS 15 Apple Silicon runner and uploads the executable, source, and documentation as an artifact.

# MauLeaf Hardware Probe

A one-shot, read-only macOS diagnostic for identifying which AppleSMC charge-control key family is exposed by this Mac. The first target is Apple Silicon running macOS 15.

## Safety boundary

- Opens the AppleSMC user client and performs metadata/read operations only.
- Contains no SMC write operation and never sends the SMC write selector.
- Does not enable or disable charging, change a charge limit, modify power settings, install a daemon, or register a login item.
- Reads adapter-input keys only for identification; they are never treated as a charge-limit backend.
- Prints the report locally. It makes no network requests and uploads no device information.

A readable key is only a capability hint. It does not prove that a later write will be permitted or that firmware will enforce a charge limit. That requires a separate hardware test and explicit approval.

## Build

The GitHub Actions workflow builds an arm64 executable targeting macOS 15 on a GitHub-hosted Apple Silicon runner. Download the MauLeafHardwareProbe-macos15-arm64 artifact from the successful workflow run.

For a local build with Xcode Command Line Tools, run:

From the repository root, run:

```bash
swiftc -O -parse-as-library -framework IOKit -framework CoreFoundation Sources/SystemFirmwareReader.swift Tools/MauLeafHardwareProbe/MauLeafHardwareProbe.swift -o MauLeafHardwareProbe
```

## Run

Run without administrator privileges first:

chmod +x ./MauLeafHardwareProbe
./MauLeafHardwareProbe

Only if the report explicitly says AppleSMC access was denied as not privileged, retry the same read-only binary with:

sudo ./MauLeafHardwareProbe

Do not run a different SMC utility alongside this diagnostic. The probe does not need to be installed and can be deleted after the report is collected.

## Interpreting the result

- Firmware-managed candidate: bfF0, bfD0, and bfE0 are readable and have the expected key shapes (or the firmware reports unpopulated size metadata but direct reads succeed). This is the preferred candidate, not proof of enforcement.
- Legacy SMC candidate: CH0B and CH0C are readable with expected shapes.
- Alternate SMC candidate: CHTE is readable with its expected shape.
- No known candidate: none of the above groups could be confirmed. Do not substitute adapter-input control keys.

The report includes the model identifier, chip string when exposed by macOS, system firmware version (read recursively from IODeviceTree), OS version/build, SMC key metadata, and raw read-only key bytes.

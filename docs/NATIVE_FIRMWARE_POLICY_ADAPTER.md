# Native firmware policy adapter - P4

## Exact target evidence

The target device is:

- Model: MacBookPro18,1 (Apple M1 Pro)
- Firmware: mBoot-20457.41.3
- macOS: 15.7.7 (24G720)
- Architecture: arm64

The read-only probe recorded:

| Key | Result | Metadata / value |
|---|---|---|
| bfF0 | Readable | 1 byte, ui8, value 0x00 |
| bfD0 | Readable | 4 bytes, ui32, value 80 |
| bfE0 | Readable | 4 bytes, ui32, value 78 |
| CH0B | Absent | Not present |
| CH0C | Absent | Not present |
| CHTE | Absent | Not present |
| CH0I | Absent | Not present |
| CH0J | Readable | 1 byte, ui8, value 0x00 |
| CHIE | Readable | 1 byte, hex_, value 0x00 |

The bf* family is a valid read-only capability candidate. It is not yet a verified production backend: write access and actual charging enforcement have not been tested on this exact model/firmware.

CH0J and CHIE are readable, but their adapter-cut semantics and correct values have not been validated on this MacBook Pro. Force-discharge therefore remains unsupported; the implementation must not infer that a key is writable or that a value is safe from key presence alone.

## Policy mapping

The adapter maps MauLeaf's current settings to a pure native-backend decision:

| Existing MauLeaf setting | Native policy action |
|---|---|
| Limited + adapter strategy | Configure the selected upper limit and a two-point lower resume threshold |
| Limited + discharge strategy | Unsupported until adapter-cut behavior is verified |
| Full + once | Temporarily deactivate, charge to 100%, then restore the saved limit |
| Full + always | Deactivate the firmware limit |

Every action is currently preview-only because the target firmware is a candidate, not a verified profile.

## Safety tiers

- verified: exact device/firmware has passed write/read-back and real enforcement tests. Automatic policy writes may be enabled only at this tier.
- candidate: required firmware keys and values are readable, but behavior is unverified. Read-only status and plans are allowed; manual hardware validation is possible with AC power and explicit confirmation; automatic writes remain disabled.
- unsupported: target identity or key evidence does not match. No firmware control plan is issued.

The classifier intentionally contains no verified profile for the target MacBookPro18,1 yet.

## Integration status

This adapter is pure Swift and unit-tested. It is not connected to the menu-bar UI, the LaunchDaemon, or the current batt workflow. No SMC writes occur in this stage.

The released application remains unchanged until the target hardware passes the dedicated AC-powered validation.

# MauLeaf architecture

The AppKit menu-bar controller hosts SwiftUI views in a single NSPanel. ChargeManager remains the single owner of observable charging state and coordinates the existing backend; UI components do not perform privileged firmware writes.

- Sources/App: application entry and termination delegate.
- Sources/MenuBar: status item, single panel, card shape, and brand assets.
- Sources/Views: panel content, settings, operation feedback, and battery ring.
- Sources/Charging: charge manager, operations, and pure charging policies.
- Sources/Power: read-only sampling, flow model, diagram and color tokens.
- Sources/Firmware: existing transport, permits, transactions, runtime, and reconciliation.
- Sources/Helper: existing privileged service, XPC protocol and client.
- Sources/Shared: localization and appearance preference.

Scripts/ci/sources.sh defines separate app and privileged Helper compile inputs. The app does not link the writable SMC transport. The original Helper implementation and protocol remain unchanged for this maintenance preview.

MagSafe LED writes are not part of version 1.2.0.

## 1.3 MagSafe LED preview

The Helper-only MagSafeLEDController uses a separate ACLC channel (green 03, automatic 00), a pure policy, and explicit read-only MagSafe port observations. It reuses the existing serialized state refresh and recovery timer, never changes charge registers or exposes raw LED writes via XPC. A durable root-owned magsafe-led.pending marker precedes each override and survives a crash; removal is blocked until the automatic handoff command succeeds. Unknown port or battery observations do not authorize green. Full real-device lifecycle testing is required.

# Winlator Fork Optimal

A device-focused Winlator fork targeting the Samsung Galaxy A06 (SM-A065M), Android 16, ARM64.

## Goals

- Prioritize stable frame pacing over misleading peak-FPS claims.
- Offer conservative, device-aware defaults for CPU translation and graphics.
- Preserve upstream compatibility and leave an easy path to revert experimental tuning.
- Keep changes measurable: document the reason, risk, and validation for each optimization.
- Provide APK builds through GitHub Actions so development does not require Termux.

## Upstream baseline

This repository currently tracks the upstream Winlator source as a pinned submodule. The initial baseline supplied for this project is the Winlator 11.2 source snapshot:

- Main repository commit: `b6b2259158cf38d06067c34430d840d56b46d220`
- App source commit: `a030f552f452158a2db64fdb32b490fa19c0b48d`
- Vortek source commit: `b1730c5def9b575672e671aee11d79ae7adc63d1`
- Gladio source commit: `116c0d14dedbea3bd057f98f1db138bb1efe225e`

Upstream project: https://github.com/brunodev85/winlator

## Device profile

The target profile is ARM64 on Android 16. Device-specific driver decisions must be based on runtime GPU/driver detection and real tests; do not assume that every Vulkan driver, DXVK version, or Box64 preset is best for every game.

## Development status

- [x] Source snapshots identified and integrity-checked.
- [x] App, Vortek, and Gladio source snapshots matched to the main repository's gitlink commits.
- [ ] Add reproducible GitHub Actions debug build.
- [ ] Establish a clean baseline build before changing runtime defaults.
- [ ] Add reversible, device-focused tuning in small commits.
- [ ] Validate installation, launch, graphics, audio, and game compatibility on the target device.

## Important

This is an independent community fork, not an official Winlator release. It must retain upstream notices and comply with the licenses of Winlator and every bundled dependency. Early builds are experimental and should not replace a known-working version until tested.

No FPS gains are claimed until measured on the target phone.
# Roadmap

Every phase stays inside the [constraints](design.md#1-constraints). All testing happens in
VMs or on spare disks, never on a live machine that someone depends on.

## Phase 0: validation

In a NixOS-unstable VM, set the base options by hand and resolve the **[verify]** items
in the [design](design.md). Then run this corpus of foreign binaries unmodified:

- manylinux wheels (`pip install numpy torch`)
- rustup and a Go release binary
- a prebuilt LLVM `ld.lld`
- an AppImage
- Playwright's Chromium
- a script with `#!/usr/bin/python3`

**Exit:** the corpus runs, and the closure has nothing to build.

Done. The container half is
[`experiments/fhs-container`](../experiments/fhs-container/). The booted-VM half
is `tests/fhs.nix` (`nix flake check`), which covers real envfs, activation, and a
systemd service without nix-ld variables. Found upstream:

- envfs did not resolve names on `readlink`, so relocatable interpreters
  (python-build-standalone) could not run through `#!/usr/bin/python3`.
  Fixed in Omnix: the base builds envfs with the fix proposed upstream as
  [Mic92/envfs#233](https://github.com/Mic92/envfs/pull/233), until nixpkgs
  ships it; `tests/fhs.nix` now expects the script to run.
- envfs on the live ISO breaks NetworkManager DNS
  ([#1](https://github.com/Omnix-Linux/Omnix/issues/1)); the ISO no longer includes
  the FHS layer.

## Status (2026-10-03)

| Phase | State |
|---|---|
| 1. Base module | Done: `modules/fhs.nix`, VM-tested |
| 2. KDE Plasma - Atrium | First version, VM-tested ([KDE Plasma - Atrium](https://github.com/Omnix-Linux/Atrium)) |
| 3. Installer | Done. `nix build .#iso` (1.5 GB, [v0.1.0](https://github.com/Omnix-Linux/Omnix/releases/tag/v0.1.0)); `tests/install-qemu.py` installs unattended over UEFI: Minimal on btrfs (boots to login), KDE Plasma - Atrium on XFS (boots to the greeter) |
| 4. Hyprland - Omarchy | `stable` and `latest` VM-tested ([Hyprland - Omarchy](https://github.com/Omnix-Linux/Autarchy)) |
| 5. Switchover | Started by the maintainer |

## Phase 1: the base

- `flake.nix` with `nixosModules.default`.
- `omnix.fhs.libraries`, the desktop preset, and envfs.
- A NixOS VM test for the corpus.

**Exit:** a NixOS-unstable system that imports the module runs the corpus.

## Phase 2: KDE Plasma - Atrium

- Write [KDE Plasma - Atrium](https://github.com/Omnix-Linux/Atrium) from scratch as a declarative KDE
  flavor.
- Pass the flavor contract.

**Exit:** KDE Plasma - Atrium installs in a VM with nothing to build except unfree drivers.

## Phase 3: installer

- `omnix-install` (gum), disko presets, `flavors.json` with Minimal and KDE Plasma - Atrium.
- `nix build .#iso`, and the first ISO on GitHub Releases.

**Exit:** boot the ISO in a VM, choose KDE Plasma - Atrium, and reboot into a working desktop.

## Phase 4: Hyprland - Omarchy

- [Hyprland - Omarchy](https://github.com/Omnix-Linux/Autarchy) `stable`, pinned to an Omarchy release.
  Then `latest`.
- Add both to the registry.

**Exit:** both variants install from the same ISO. This is the reproducibility proof.

## Phase 5: switchover

The maintainer's own workstation moves from its plain-NixOS configuration to a private
machine flake that imports Omnix and KDE Plasma - Atrium. The maintainer starts this step; no phase
triggers it automatically.

## v2

- Dual-boot: install into free space beside another OS.
- Third-party flavors, by pull request and contract check.
- An `omnix flavor switch` helper.
- Small fixes sent upstream to nixpkgs, such as the nix-ld docs and library list.

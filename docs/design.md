# Omnix design

Status: draft. Items marked **[verify]** are assumptions that the [roadmap](roadmap.md)'s
Phase 0 must confirm.

## 1. Constraints

These are hard rules. A change that breaks one is rejected, however useful it is.

1. **No compute budget.** Installing Omnix or any listed flavor compiles nothing
   locally. Two exceptions are allowed:
   - trivial derivations: symlink trees and text files;
   - unfree packages (the NVIDIA driver, VS Code), which `cache.nixos.org` does not
     carry (checked at nixos-unstable `c59305b`).
2. **Hosting only for installer ISOs.** Omnix publishes ISOs on GitHub Releases and
   nothing else. It has no binary cache, channel, or website.
3. **A minimal base.** The base provides FHS compatibility and nothing else. Desktops
   and opinions live in flavors (§6).
4. **Never change nixpkgs packages.** There are no overlays and no patches. A changed
   package has a different store path, so it is no longer in the cache, which breaks
   rule 1.
5. **One nixpkgs: `nixos-unstable`.** The base and every flavor follow it, pinned by
   `flake.lock`.

## 2. Architecture

```
  machine       your flake: user, hardware, disk, local tweaks     (owned by the user)
     │ imports
  flavor        KDE Plasma - Atrium | Hyprland - Omarchy | Minimal
                (one repository per desktop)
     │ imports
  base          Omnix: nix-ld + /usr/lib + envfs                     (Omnix-Linux/Omnix)
     │ on
  nixpkgs       nixos-unstable, unmodified, from cache.nixos.org
```

Dependencies only point down the stack. If a flavor needs a hack in the base, that
means the base has a bug.

## 3. Problem

Prebuilt binaries expect these paths. Stock NixOS has only `/bin/sh` and `/usr/bin/env`.

| Path | Used for |
|---|---|
| `/lib64/ld-linux-x86-64.so.2` | ELF interpreter (`PT_INTERP`) |
| `/usr/lib`, `/lib` | Libraries the binary links against |
| `/usr/bin/python3`, `/bin/bash`, `/bin/true`, … | Shebangs and hard-coded tool paths |

## 4. The base: FHS layer

The guiding rule is **add, never relocate.** `/nix/store` is untouched, so every store
path still matches `cache.nixos.org`.

### 4.1 Loader: nix-ld

`programs.nix-ld` (in nixpkgs) puts a shim at `/lib64/ld-linux-x86-64.so.2`. The shim
hands off to the real glibc loader with the declared library path. The base enables it
and sets its libraries (§4.2). Omnix never builds a loader of its own, because that
would mean compiling glibc (rule 1).

Setting `programs.nix-ld.libraries` *adds to* the module's defaults. The module
sets them in `config`, so the lists merge, and the base does not restate them
(confirmed by the [container experiment](../experiments/fhs-container/)).

nix-ld 2.0.6 has the library path compiled in
(`/run/current-system/sw/share/nix-ld/lib`). Processes that have no
`NIX_LD_LIBRARY_PATH` therefore still work: systemd services, cron, and
`ssh host cmd`. The experiment runs its whole corpus without the variables.

### 4.2 Libraries

The base set is taken from a workstation where these libraries have been needed in
practice:

| Group | Libraries |
|---|---|
| nix-ld defaults (restated) | zlib, zstd, stdenv.cc.cc, curl, openssl, attr, libssh, bzip2, libxml2, acl, libsodium, util-linux, xz, systemd |
| C/C++ runtime | stdenv.cc.cc.lib, libffi, libxcrypt, elfutils, libunwind |
| Legacy crypt | libxcrypt-legacy (`libcrypt.so.1`; uv's prebuilt CPython 3.10/3.11 need it) |
| Console and scripting | ncurses, readline, sqlite, expat, pcre2, icu |
| Compression | lz4, brotli, snappy |
| Soname shims | `libxml2.so.2` → current libxml2 (prebuilt LLVM `ld.lld` asks for the old soname) |

The **desktop preset** (`omnix.fhs.presets.desktop`) is defined in the base but switched
off. Desktop flavors switch it on. It adds the libraries that Electron apps,
Playwright browsers and prebuilt GTK, Qt and Tauri apps need: glib, gtk3, cairo,
pango, atk, gdk-pixbuf, at-spi2, nss, nspr, dbus, fontconfig, freetype, libGL, libdrm,
libxkbcommon, mesa, libgbm, vulkan-loader, the X11 client libraries, webkitgtk_4_1,
libsoup_3, alsa-lib, libpulseaudio, and cups.

The same library tree is exposed at the standard paths, through `/run/current-system` so
that rollbacks just work:

```
/usr/lib -> /run/current-system/sw/share/nix-ld/lib
/lib     -> /usr/lib
```

### 4.3 `ldconfig` and `ld.so.cache`

Foreign code also discovers libraries by asking `ldconfig`. Python's
`ctypes.util.find_library` runs `/sbin/ldconfig -p`, and returned nothing in
every configuration until this was added. nixpkgs' `ldconfig` reads its cache
from its own store path unless it is given `-C`. Activation therefore:

- installs `/sbin/ldconfig`, a two-line wrapper that runs the glibc `ldconfig`
  with `-C /etc/ld.so.cache`;
- regenerates `/etc/ld.so.cache` from `/usr/lib` on every switch.

Both are text and a cache file, so no compute is needed (rule 1). The cache only
answers queries; the loaders never read it (§4.1).

### 4.4 Executables: envfs

`services.envfs.enable` mounts `/bin` and `/usr/bin` as a filesystem that resolves any
name on `PATH`. That makes `#!/usr/bin/python3`, `/bin/true` and `/bin/bash` work.

An earlier draft preferred a declared list of symlinks for predictability. Real use
showed such lists go stale, while envfs fixed failures in test suites that hard-code
`/bin/*`. envfs invents nothing: only names already on `PATH` resolve.

### 4.5 Known gap: binaries that use the store loader

Some binaries have a `/nix/store` glibc as their interpreter rather than
`/lib64/ld-linux…`. They never pass through nix-ld, and the store loader does not
search `/usr/lib`. Examples:

- rustup's `librustc_driver`;
- shims that rely on `$ORIGIN`;
- Rust binaries linked here with `rust-lld`.

The base does not solve this case. Flavors may add targeted workarounds, but the gap is
documented rather than hidden.

### 4.6 Diagnostics note

**Do not diagnose with `ldd`.** It calls the loader directly, bypasses the nix-ld shim,
and reports working foreign binaries as missing libraries. Run the binary itself, or
compare `patchelf --print-needed` with `ls /usr/lib`.

## 5. Purity

- **Nix builds cannot see `/usr/lib`.** The build sandbox has no `/usr`, so derivations
  stay pure.
- **Native binaries do not use nix-ld.** Their interpreter is a store path.
- **The library set is declared.** The same configuration gives the same `/usr/lib`.

## 6. Flavors

### 6.1 Contract

A flavor is a flake that exports one or more `nixosModules`. Every listed flavor must:

1. **Follow the base.** Set `inputs.nixpkgs.follows` and `inputs.omnix.follows`.
2. **Be cache-clean.** `nix build --dry-run` on a reference machine shows nothing under
   "will be built", apart from the rule 1 exceptions. This check only evaluates the
   configuration and needs no build compute.
3. **Contain nothing personal.** No usernames, hardware, keys, or hosts. The installer
   and the machine flake supply those.
4. **Be declarative.** No captured dotfiles copied in. Desktop state is declared through
   home-manager and plasma-manager.
5. **Be listed in [`flavors.json`](../flavors.json).** Third-party flavors can join
   later, by pull request, if they pass this contract.

### 6.2 Variants

A flavor repository can export several modules. The registry names the one to use.
Hyprland - Omarchy exports:

- `stable`: a pinned Omarchy release;
- `latest`: follows Omarchy's main branch.

### 6.3 Switching

The machine flake has a single `flavor` input. Switching means changing that URL (and
module name), then `nixos-rebuild switch`. The previous flavor stays in the boot menu
until garbage collection. An `omnix flavor switch <id>` helper may wrap this later.

## 7. Installer

The ISO is the stock nixpkgs minimal installer, plus the base and a `gum`-based text
menu called `omnix-install`. Its steps:

1. **Network:** `nmtui`. Everything after this step downloads.
2. **Disk:** the whole chosen disk is used (v1). The user picks a filesystem, and none
   is preselected:
   - ext4;
   - btrfs with snapshots;
   - XFS with reflink, which is fast for copy-heavy builds such as Rust.

   There is a LUKS encryption toggle, and partitioning is done with disko. Installing
   into free space beside another OS comes in **v2**.
3. **Flavor:** chosen from `flavors.json`.
4. **User:** username, password, timezone.
5. **Hardware:** `nixos-generate-config`. If `lspci` shows an NVIDIA GPU, the installer
   enables `hardware.nvidia` with nixpkgs' default production driver. Driver overrides
   are not part of Omnix.
6. **Generate** `/mnt/etc/nixos/flake.nix`. Unfree software is allowed by default.
7. **Install:** `nixos-install --flake /mnt/etc/nixos#omnix`, then reboot.

The generated machine flake looks like this:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    omnix = { url = "github:Omnix-Linux/Omnix"; inputs.nixpkgs.follows = "nixpkgs"; };
    flavor = {
      url = "github:Omnix-Linux/Atrium";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.omnix.follows = "omnix";
    };
  };

  outputs = { nixpkgs, omnix, flavor, ... }: {
    nixosConfigurations.omnix = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        omnix.nixosModules.default
        flavor.nixosModules.default      # the registry's "module" field
        ./hardware-configuration.nix
        ./disko.nix
        ./local.nix                      # user, timezone, GPU, allowUnfree
      ];
    };
  };
}
```

### 7.1 ISO and hosting

| Image | Size | Hosting |
|---|---|---|
| Minimal installer (the only one) | about 1–1.5 GB | GitHub Releases (free, 2 GiB per file) |

Flavor packages are not on the ISO. They download during install. Anyone can build the
image with `nix build github:Omnix-Linux/Omnix#iso`. Only the latest one or two releases keep
their images.

## 8. Out of scope

| Idea | Why not |
|---|---|
| A custom glibc or loader | Needs compute and a cache (rules 1 and 2) |
| A stable-nixpkgs variant of the base | Doubles testing. Rule 5 |
| Overlays or driver overrides in the base or flavors | Rule 4. They belong in a user's machine flake |
| A graphical installer ISO | Over 2 GiB. The text installer covers it |
| Offline installation | Flavors download by design |

## 9. Open questions

1. Whether NixOS activation conflicts with the `/usr/lib` and `/lib` links, and whether
   envfs replacing `/usr/bin/env` and `/bin/sh` is safe on every flavor.
2. aarch64: map the paths to `/lib/ld-linux-aarch64.so.1`.

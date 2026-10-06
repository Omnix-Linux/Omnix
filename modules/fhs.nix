# Omnix base: the standard Linux library layout on NixOS (docs/design.md §4).
#
#   /lib64/ld-linux-x86-64.so.2  nix-ld's loader shim
#   /usr/lib, /lib               the nix-ld library tree
#   /sbin/ldconfig               glibc's ldconfig on /etc/ld.so.cache
#   /etc/ld.so.cache             rebuilt from /usr/lib on boot and every switch
#   /bin, /usr/bin               envfs: any name on the caller's PATH
#   /usr/share/X11/{xkb,locale}  keymaps and compose tables (desktop preset)
#
# Everything comes from nixpkgs as-is (rule 4); the only local builds are
# symlink trees and text files (rule 1). One deliberate exception: envfs carries
# Omnix's fix for resolving names on readlink (envfs-readlink below) until
# nixpkgs ships it, so envfs itself is built locally.
{ config, lib, pkgs, ... }:
let
  cfg = config.omnix.fhs;

  # envfs resolves /usr/bin/NAME on exec but not on readlink, so a relocatable
  # interpreter (python-build-standalone) started through #!/usr/bin/python3 can't
  # find its stdlib. Omnix's fix, proposed upstream as Mic92/envfs#233, applied
  # here until a nixpkgs release includes it. Drop this when it does.
  envfs-readlink = pkgs.envfs.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (pkgs.fetchpatch {
        name = "envfs-resolve-on-readlink.patch";
        url = "https://github.com/zackees/envfs/commit/9424a75731905637631f4fa70d0ac3105b088d04.patch";
        hash = "sha256-lymqTRQ4zoxvAe6rcvRICzQYSkhHigvs2UE75xTL6JE=";
      })
    ];
  });

  # Sonames nixpkgs no longer ships under the name foreign binaries ask for.
  legacySonameShims = pkgs.runCommand "omnix-legacy-soname-shims" { } ''
    mkdir -p $out/lib
    # libxml2 moved to .so.16 in 2.15; prebuilt LLVM tools still ask for .so.2.
    ln -s ${pkgs.libxml2.out}/lib/libxml2.so $out/lib/libxml2.so.2
  '';

  # §4.2. nix-ld's own defaults (zlib, openssl, systemd, ...) merge in.
  baseLibraries = with pkgs; [
    stdenv.cc.cc.lib libffi libxcrypt elfutils libunwind
    libxcrypt-legacy
    ncurses readline sqlite expat pcre2 icu
    lz4 brotli snappy
    legacySonameShims
  ];

  desktopLibraries = with pkgs; [
    glib gtk3 cairo pango atk gdk-pixbuf at-spi2-atk at-spi2-core
    nss nspr dbus fontconfig freetype
    libGL libdrm libxkbcommon mesa libgbm vulkan-loader
    libx11 libxcomposite libxdamage libxext libxfixes libxrandr libxrender libxi libxtst
    libxscrnsaver libxcb libxcursor libxshmfence
    webkitgtk_4_1 libsoup_3 alsa-lib libpulseaudio cups
  ];

  libraryTree = "/run/current-system/sw/share/nix-ld/lib";

  # nixpkgs' ldconfig reads a cache inside its own store path unless given -C.
  ldconfig = pkgs.writeShellScript "ldconfig" ''
    exec ${pkgs.glibc.bin}/bin/ldconfig -C /etc/ld.so.cache "$@"
  '';
in
{
  options.omnix.fhs = {
    enable = lib.mkEnableOption "the standard Linux library layout" // {
      default = true;
    };
    libraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra libraries for /usr/lib, beyond the base set.";
    };
    presets.desktop = lib.mkEnableOption ''
      the desktop library set: GTK, WebKitGTK, mesa, X11 and audio clients, for
      Electron apps, Playwright browsers and prebuilt GUI tools
    '';
  };

  config = lib.mkIf cfg.enable {
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries =
      baseLibraries ++ lib.optionals cfg.presets.desktop desktopLibraries ++ cfg.libraries;

    services.envfs.enable = true;
    services.envfs.package = envfs-readlink;

    systemd.tmpfiles.rules = [
      "L+ /usr/lib - - - - ${libraryTree}"
      "L+ /lib - - - - /usr/lib"
      "d /sbin 0755 root root - -"
      "L+ /sbin/ldconfig - - - - ${ldconfig}"
    ] ++ lib.optionals cfg.presets.desktop [
      # Prebuilt GUI apps that bundle libxkbcommon or libX11 (kitty, GLFW and SDL
      # apps) look for keymaps and compose tables at the standard X11 paths.
      "d /usr/share 0755 root root - -"
      "d /usr/share/X11 0755 root root - -"
      "L+ /usr/share/X11/xkb - - - - ${pkgs.xkeyboard_config}/share/X11/xkb"
      "L+ /usr/share/X11/locale - - - - ${pkgs.libx11}/share/X11/locale"
    ];

    # Python's ctypes.util.find_library asks `/sbin/ldconfig -p`. The cache only
    # answers queries; no loader reads it (§4.3).
    systemd.services.omnix-ldconfig = {
      description = "Rebuild /etc/ld.so.cache from /usr/lib";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      restartTriggers = [ config.programs.nix-ld.libraries ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${ldconfig} -f /dev/null -X /usr/lib";
      };
    };
  };
}

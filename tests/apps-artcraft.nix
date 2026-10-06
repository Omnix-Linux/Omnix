# More ArtCraft apps (storytold, Apache-2.0), run exactly like FilmCraft in
# tests/apps-gui.nix: the unmodified upstream linux-x86_64 tarball, through
# nix-ld and the FHS tree, in the same IceWM session.
{ pkgs, guiTest }:
let
  # Hashes match each release's SHA256SUMS.txt.
  apps = {
    photocraft = { version = "0.2.0"; hash = "sha256-LVWu2WhBhEf1FKyH5qPx6z34hfDjtGvATlQSL1LHdDA="; };
    vectorcraft = { version = "0.3.0"; hash = "sha256-DI0AiQGGHO5bSTVJy8V+ytrkWTdO10j1A23fMzfAaDU="; };
    lightcraft = { version = "0.2.0"; hash = "sha256-8DZiDsSigyO/udXwIZWp6H3hOh2sknAbnjRZ6yhkRh8="; };
    printcraft = { version = "0.2.0"; hash = "sha256-UK1Ut++85wrz4fzCPnKCBCAd+eM6leNdTy1Dl4AZktM="; };
    effectcraft = { version = "0.3.0"; hash = "sha256-Isvx+aORBpgIBZf0gBr1pMCIEkYPrdEJa9pVuD2+8JM="; };
    designcraft = { version = "0.2.0"; hash = "sha256-YClqomqJk82jLPNzB3cTsz10BGF0ze7i+myslKSba90="; };
  };

  artcraftTest = name: { version, hash }:
    let
      tarball = pkgs.fetchurl {
        url = "https://github.com/storytold/${name}/releases/download/v${version}/${name}-${version}-linux-x86_64.tar.gz";
        inherit hash;
      };
    in
    guiTest name { } ''
      machine.succeed("mkdir -p /opt/${name}")
      machine.succeed("tar -xzf ${tarball} -C /opt/${name} --strip-components=1")

      with subtest("CLI and --version run"):
          print(machine.succeed("/opt/${name}/bin/${name}-cli --version"))
          print(machine.succeed("/opt/${name}/bin/${name} --version"))
          machine.succeed("/opt/${name}/bin/${name}-cli --version | grep -q '${name}-cli ${version}'")
          machine.succeed("/opt/${name}/bin/${name} --version | grep -q '${name} ${version}'")

      with subtest("main window appears"):
          # A transient unit, so the app outlives the shell that started it.
          machine.succeed(
              "systemd-run --unit=${name} -E DISPLAY=:0 -E LIBGL_ALWAYS_SOFTWARE=1 -E HOME=/root"
              " /opt/${name}/bin/${name}"
          )
          machine.wait_until_succeeds("DISPLAY=:0 xdotool search --onlyvisible --name ${name}", timeout=120)
          machine.succeed("sleep 10")
          machine.succeed("systemctl is-active ${name}")
          print(machine.succeed("DISPLAY=:0 xdotool search --onlyvisible --name ${name} getwindowname %@"))
          machine.screenshot("${name}")
    '';
in
builtins.mapAttrs artcraftTest apps

# Boots an X11 session on the Omnix base with the desktop library preset and
# launches real GUI apps to their main window, taking a screenshot of each.
# IceWM with root autologin (nixpkgs' test x11 profile) keeps the session small.
{ pkgs, module }:
let
  # The VM has no network: the upstream release arrives as a fixed-output
  # fetch. The hash matches the release's SHA256SUMS.txt
  # (35743d04...b0136d5a09). The tarball, not the AppImage, so no FUSE.
  filmcraft = pkgs.fetchurl {
    url = "https://github.com/storytold/filmcraft/releases/download/v0.2.0/filmcraft-0.2.0-linux-x86_64.tar.gz";
    hash = "sha256-NXQ9BI/NlCof42uMlfCvezzn1VdzJa+r+uEIMXXSL6U=";
  };

  guiTest = name: extra: script: pkgs.testers.runNixOSTest {
    name = "omnix-app-${name}";
    nodes.machine = {
      imports = [ module "${pkgs.path}/nixos/tests/common/x11.nix" extra ];
      omnix.fhs.presets.desktop = true;
      environment.systemPackages = [ pkgs.gnutar pkgs.gzip pkgs.xdotool ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 4;
    };
    enableOCR = false;
    testScript = ''
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("omnix-ldconfig.service")
      machine.wait_for_x()
    '' + script;
  };
in
{
  # The unmodified upstream binary, running through nix-ld and the FHS tree.
  filmcraft = guiTest "filmcraft" { } ''
    machine.succeed("mkdir -p /opt/filmcraft")
    machine.succeed("tar -xzf ${filmcraft} -C /opt/filmcraft --strip-components=1")

    with subtest("CLI and --version run"):
        machine.succeed("/opt/filmcraft/bin/filmcraft-cli --version | grep -q 'filmcraft-cli 0.2.0'")
        machine.succeed("/opt/filmcraft/bin/filmcraft --version | grep -q 'filmcraft 0.2.0'")

    with subtest("main window appears"):
        # A transient unit, so the app outlives the shell that started it.
        machine.succeed(
            "systemd-run --unit=filmcraft -E DISPLAY=:0 -E LIBGL_ALWAYS_SOFTWARE=1 -E HOME=/root"
            " /opt/filmcraft/bin/filmcraft"
        )
        machine.wait_until_succeeds("DISPLAY=:0 xdotool search --onlyvisible --name filmcraft", timeout=120)
        machine.succeed("sleep 10")
        machine.succeed("systemctl is-active filmcraft")
        print(machine.succeed("DISPLAY=:0 xdotool search --onlyvisible --name filmcraft getwindowname %@"))
        machine.screenshot("filmcraft")
  '';

  # OBS publishes only Ubuntu .debs, so this is the nixpkgs build.
  obs = guiTest "obs" { environment.systemPackages = [ pkgs.obs-studio ]; } ''
    with subtest("--version runs"):
        machine.succeed("obs --version")

    with subtest("main window appears"):
        machine.succeed("mkdir -p /root/.config")
        # A transient unit, so the app outlives the shell that started it.
        machine.succeed(
            "systemd-run --unit=obs -E DISPLAY=:0 -E LIBGL_ALWAYS_SOFTWARE=1 -E HOME=/root"
            " obs --disable-shutdown-check --disable-updater"
        )
        machine.wait_until_succeeds("DISPLAY=:0 xdotool search --onlyvisible --name 'OBS [0-9]'", timeout=180)
        machine.succeed("sleep 15")
        machine.succeed("systemctl is-active obs")
        print(machine.succeed("DISPLAY=:0 xdotool search --onlyvisible --name 'OBS' getwindowname %@"))
        machine.screenshot("obs")
  '';
}

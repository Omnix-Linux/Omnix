# Boots an X11 session on the Omnix base with the desktop library preset and
# launches real GUI apps to their main window, taking a screenshot of each.
# IceWM with root autologin (nixpkgs' test x11 profile) keeps the session small.
{ pkgs, module, obs-studio ? pkgs.obs-studio }:
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
  # Shared with tests/apps-artcraft.nix.
  inherit guiTest;

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
  # Omnix's OBS: nixpkgs' build plus the fixes in pkgs/obs-studio.nix.
  obs = guiTest "obs" { environment.systemPackages = [ obs-studio pkgs.wmctrl ]; } ''
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

    # A wrong plugin path still opens the window, just with no capture sources or
    # encoders, so require OBS's output to list its core modules as loaded.
    with subtest("core modules load"):
        obs_log = machine.succeed("journalctl -u obs --no-pager -o cat")
        assert "Failed to load core module" not in obs_log, "a core module failed to load"
        print("\n".join(l for l in obs_log.splitlines() if "Loaded Modules" in l or l.strip().startswith(("obs-ffmpeg", "linux-capture", "linux-pipewire", "obs-x264"))))
        for module in ("obs-ffmpeg", "linux-capture", "obs-x264"):
            assert module in obs_log, f"{module} did not load"

    # Omnix's patch guards the graphics teardown that runs after obs_shutdown()
    # (obsproject/obs-studio#13906). Close OBS the normal way and require a clean
    # exit: the unit must finish with Result=success and leave no core dump.
    with subtest("quits cleanly"):
        machine.succeed("DISPLAY=:0 xdotool key Escape")  # dismiss the first-run wizard
        machine.succeed("sleep 2")
        machine.succeed("DISPLAY=:0 wmctrl -c 'OBS 3'")
        machine.wait_until_fails("systemctl is-active obs", timeout=60)
        result = machine.succeed("systemctl show obs -p Result --value").strip()
        print("obs unit result:", result)
        assert result == "success", result
        machine.fail("coredumpctl --no-pager list obs")
  '';
}

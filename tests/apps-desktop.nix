# Desktop apps on the Omnix base in an X11 session (same setup as
# apps-gui.nix): Brave, Telegram and kitty are the vendors' own Linux builds
# from GitHub releases, run unmodified through nix-ld and the FHS tree.
# Signal and Slack publish only apt/.deb/.rpm packages, so they come from
# nixpkgs. The session logs in as root, so Chromium/Electron apps need
# --no-sandbox (Chromium refuses to run as root otherwise).
{ pkgs, module }:
let
  # Hash matches brave-browser-1.96.61-linux-amd64.zip.sha256 from the release.
  brave = pkgs.fetchurl {
    url = "https://github.com/brave/brave-browser/releases/download/v1.96.61/brave-browser-1.96.61-linux-amd64.zip";
    sha256 = "c68cf179603470e8001a949294fe98b593f0749ca95f42687d855081b1c394a4";
  };
  # No checksum file is published; this matches GitHub's asset digest.
  telegram = pkgs.fetchurl {
    url = "https://github.com/telegramdesktop/tdesktop/releases/download/v7.2.9/td-setup-linux-x64-7.2.9.tar.xz";
    sha256 = "dc0698eb8011ed4e75f1fad9d55a8ab54e375c9791b9c577baa6073d9a4c50fa";
  };
  # The release ships a GPG .sig, not a sha256 file; matches GitHub's asset digest.
  kitty = pkgs.fetchurl {
    url = "https://github.com/kovidgoyal/kitty/releases/download/v0.49.2/kitty-0.49.2-x86_64.txz";
    sha256 = "d573618b911e9c461bd421b96c13c74c7f1cb2f1ac9c327818d4ff84366cf5c6";
  };
  # Slack is unfree; allow just it, just here.
  unfreePkgs = import pkgs.path {
    inherit (pkgs) system;
    config.allowUnfreePredicate = p: (pkgs.lib.getName p) == "slack";
  };

  guiTest = name: extra: script: pkgs.testers.runNixOSTest {
    name = "omnix-app-${name}";
    nodes.machine = {
      imports = [ module "${pkgs.path}/nixos/tests/common/x11.nix" extra ];
      omnix.fhs.presets.desktop = true;
      environment.systemPackages = [ pkgs.gnutar pkgs.xz pkgs.unzip pkgs.xdotool ];
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

  # Start an app in a transient unit, wait for its window, screenshot it.
  launch = { unit, cmd, cls, timeout ? 180, env ? "", home ? "/root", user ? null }: ''
    machine.succeed(
        "systemd-run --unit=${unit} ${pkgs.lib.optionalString (user != null) "--uid=${user} "}-E DISPLAY=:0 -E LIBGL_ALWAYS_SOFTWARE=1 -E HOME=${home} ${env}"
        " ${cmd}"
    )
    machine.wait_until_succeeds("DISPLAY=:0 xdotool search --onlyvisible --class '${cls}'", timeout=${toString timeout})
    machine.succeed("sleep 20")
    machine.succeed("systemctl is-active ${unit}")
    print("window: " + machine.succeed("DISPLAY=:0 xdotool search --onlyvisible --class '${cls}' getwindowname %@"))
    print(machine.execute("journalctl -u ${unit} --no-pager | tail -n 40")[1])
    machine.screenshot("${unit}")
  '';
in
{
  brave = guiTest "brave" { } (''
    machine.succeed("mkdir -p /opt/brave && unzip -q ${brave} -d /opt/brave")

    with subtest("--version runs"):
        print(machine.succeed("/opt/brave/brave --version"))
  '' + launch {
    unit = "brave";
    cls = "brave";
    cmd = "/opt/brave/brave --no-sandbox --user-data-dir=/root/brave-profile --no-first-run about:blank";
  });

  telegram = guiTest "telegram" { } (''
    machine.succeed("mkdir -p /opt && tar -xJf ${telegram} -C /opt")
  '' + launch {
    unit = "telegram";
    cls = "TelegramDesktop";
    cmd = "/opt/Telegram/Telegram";
  });

  kitty = guiTest "kitty" { } (''
    machine.succeed("mkdir -p /opt/kitty && tar -xJf ${kitty} -C /opt/kitty")

    with subtest("--version runs"):
        print(machine.succeed("/opt/kitty/bin/kitty --version"))

    # Known gap: kitty's bundled libxkbcommon looks for keymaps in
    # /usr/share/X11/xkb, which the Omnix FHS layer does not provide. The
    # unmodified launch must fail with exactly that error until it does.
    with subtest("known gap: unmodified launch has no /usr/share/X11/xkb"):
        machine.fail("test -e /usr/share/X11/xkb")
        out = machine.fail("DISPLAY=:0 HOME=/root timeout 30 /opt/kitty/bin/kitty true 2>&1")
        print(out)
        assert "failed to add default include path /usr/share/X11/xkb" in out
        assert "GLFW initialization failed" in out
  '' + launch {
    unit = "kitty";
    cls = "kitty";
    # The one thing missing above, pointed at explicitly. PATH as a login
    # session has it (systemd-run's default PATH has no NixOS bin dirs).
    env = "-E XKB_CONFIG_ROOT=${pkgs.xkeyboard_config}/share/X11/xkb -E PATH=/run/current-system/sw/bin";
    cmd = "/opt/kitty/bin/kitty sh -c 'echo OMNIX-KITTY-OK > /tmp/kitty-ran; uname -a; echo OMNIX-KITTY-OK; exec sh'";
  } + ''
    machine.succeed("grep -q OMNIX-KITTY-OK /tmp/kitty-ran")
  '');

  signal = guiTest "signal" { environment.systemPackages = [ pkgs.signal-desktop ]; } (''
  '' + launch {
    unit = "signal";
    cls = "signal";
    cmd = "signal-desktop --no-sandbox";
  });

  # Slack relaunches itself without --no-sandbox, so as root its child dies
  # with "Running as root without --no-sandbox is not supported". Run it as
  # a normal user instead, as anyone would, with the sandbox on.
  slack = guiTest "slack" {
    environment.systemPackages = [ unfreePkgs.slack pkgs.xhost ];
    users.users.alice = { isNormalUser = true; uid = 1000; };
  } (''
    machine.succeed("DISPLAY=:0 xhost +si:localuser:alice")
  '' + launch {
    unit = "slack";
    cls = "slack";
    user = "alice";
    home = "/home/alice";
    cmd = "slack";
  });
}

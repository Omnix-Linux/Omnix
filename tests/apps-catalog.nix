# Compatibility workflows for the terminal, browser and communication catalogs.
# Existing vendor-binary Kitty/Brave and Telegram/Signal/Slack checks stay separate.
{ pkgs, module }:
let
  unfreePkgs = import pkgs.path {
    inherit (pkgs) system;
    config.allowUnfreePredicate = p: builtins.elem (pkgs.lib.getName p) [ "google-chrome" "discord" "discord-unwrapped" ];
  };
  helium = pkgs.fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/0.18.3.1/helium-0.18.3.1-x86_64_linux.tar.xz";
    # GitHub's published asset SHA-256, verified again by the fixed-output fetch.
    sha256 = "89bd962ca5e5159916a4c4befa5a9a08f540d2d8cd794f2f955e8d5d4a463bf2";
  };
  terminalProbe = pkgs.writeShellScript "terminal-probe" ''
    set -eu
    name=$1
    test -t 0
    test -t 1
    test -n "$TERM"
    test "$(tput colors)" -gt 0
    printf '\033[32mOmnix terminal compatibility\033[0m\nUTF-8: café λ →\n'
    printf 'PTY=ok TERM=%s COLORS=%s\n' "$TERM" "$(tput colors)" > "/tmp/terminal-$name-ready"
    cat "/tmp/terminal-$name-ready"
    exec bash --noprofile --norc
  '';
  elementLaunch = pkgs.writeShellScript "element-with-keyring" ''
    set -eu
    # An isolated, unlocked keyring for the VM's account-free startup check.
    printf %s vm-test-keyring-password | ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --unlock --components=secrets
    exec element-desktop --password-store=gnome-libsecret
  '';
  mkTest = name: packages: script: pkgs.testers.runNixOSTest {
    name = "omnix-catalog-${name}";
    nodes.machine = {
      imports = [ module "${pkgs.path}/nixos/tests/common/x11.nix" ];
      omnix.fhs.presets.desktop = true;
      environment.systemPackages = packages ++ [ pkgs.bash pkgs.coreutils pkgs.ncurses
        pkgs.xdotool pkgs.xhost pkgs.dbus pkgs.util-linux pkgs.python3 pkgs.gnutar pkgs.xz ];
      fonts.packages = [ pkgs.dejavu_fonts ];
      users.users.alice = { isNormalUser = true; uid = 1000; };
      virtualisation.memorySize = 4096;
      virtualisation.cores = 4;
    };
    enableOCR = false;
    testScript = ''
      import shlex

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("omnix-ldconfig.service")
      machine.wait_for_x()
      machine.succeed("DISPLAY=:0 xhost +si:localuser:alice")
      machine.succeed("install -d -o alice -g users -m700 /run/user/1000")

      def launch(name, command, window_class):
          machine.succeed(
              "systemd-run --unit=check-" + name + " --uid=alice --property=TimeoutStopSec=5s "
              "-E DISPLAY=:0 -E HOME=/home/alice -E XDG_RUNTIME_DIR=/run/user/1000 "
              "-E LIBGL_ALWAYS_SOFTWARE=1 -E GDK_BACKEND=x11 "
              "-E PATH=/run/current-system/sw/bin dbus-run-session -- " + command
          )
          search = "DISPLAY=:0 xdotool search --onlyvisible --class " + shlex.quote(window_class)
          try:
              machine.wait_until_succeeds(search, timeout=60)
          except Exception:
              print(machine.succeed("journalctl -u check-" + name + " --no-pager"))
              print(machine.succeed("DISPLAY=:0 xwininfo -root -tree"))
              machine.screenshot(name + "-failure")
              raise
          return machine.succeed(search).strip().splitlines()[-1]

      def evidence(name):
          machine.succeed("sleep 3; systemctl is-active check-" + name)
          print(machine.succeed("journalctl -u check-" + name + " --no-pager | tail -n 12"))
          machine.screenshot(name)
          print("OMNIX-CATALOG-PASS " + name)
          machine.succeed("systemctl stop check-" + name)
    '' + script;
  };
in
{
  terminals = mkTest "terminals" [ pkgs.tmux pkgs.wezterm pkgs.alacritty pkgs.ghostty pkgs.xterm ] ''
    terminals = [
        ("wezterm", "wezterm --skip-config start --always-new-process -- ${terminalProbe} wezterm", "org.wezfurlong.wezterm"),
        ("alacritty", "alacritty -e ${terminalProbe} alacritty", "Alacritty"),
        ("ghostty", "ghostty -e ${terminalProbe} ghostty", "com.mitchellh.ghostty"),
        ("xterm", "xterm -e ${terminalProbe} xterm", "XTerm"),
    ]
    for name, command, window_class in terminals:
        with subtest(name + " shell, PTY, terminfo and keyboard input"):
            print(machine.succeed(name + " --version" if name != "xterm" else "xterm -version"))
            window = launch(name, command, window_class)
            machine.wait_until_succeeds("test -s /tmp/terminal-" + name + "-ready")
            print(machine.succeed("cat /tmp/terminal-" + name + "-ready"))
            machine.succeed("DISPLAY=:0 xdotool windowactivate --sync " + window)
            command = "printf OMNIX-INPUT-OK > /tmp/input-" + name
            machine.succeed("DISPLAY=:0 xdotool type --clearmodifiers -- " + shlex.quote(command))
            machine.succeed("DISPLAY=:0 xdotool key Return")
            machine.wait_until_succeeds("grep -q OMNIX-INPUT-OK /tmp/input-" + name)
            evidence(name)

    with subtest("tmux session, panes, shell input and reattach"):
        print(machine.succeed("tmux -V"))
        tmux = "runuser -u alice -- tmux -L omnix-test -f /dev/null "
        machine.succeed(tmux + "new-session -d -s compatibility bash")
        machine.succeed(tmux + "send-keys -t compatibility " + shlex.quote("echo OMNIX-TMUX-OK; printf OMNIX-TMUX-OK > /tmp/tmux-ran") + " C-m")
        machine.wait_until_succeeds("grep -q OMNIX-TMUX-OK /tmp/tmux-ran")
        machine.succeed(tmux + "split-window -h -t compatibility bash")
        assert len(machine.succeed(tmux + "list-panes -t compatibility").strip().splitlines()) == 2
        window = launch("tmux", "xterm -T 'Omnix tmux check' -e tmux -L omnix-test attach-session -t compatibility", "XTerm")
        machine.wait_until_succeeds(tmux + "list-clients | grep -q compatibility")
        machine.screenshot("tmux")
        machine.succeed(tmux + "detach-client -s compatibility")
        machine.succeed(tmux + "has-session -t compatibility")
        print("OMNIX-CATALOG-PASS tmux")
        machine.succeed(tmux + "kill-server")
  '';

  browsers = mkTest "browsers" [ unfreePkgs.google-chrome pkgs.chromium pkgs.firefox ] ''
    machine.succeed("mkdir -p /opt/helium; tar -xJf ${helium} -C /opt/helium --strip-components=1")
    machine.succeed("mkdir -p /tmp/browser-fixtures")
    for name in ["chrome", "chromium", "firefox", "helium"]:
        page = '<!doctype html><meta charset="utf-8"><title>Omnix browser check ' + name + '</title><h1>Omnix browser check</h1><p>' + name + ' loaded a local page.</p><p>UTF-8: café λ →</p><script>fetch("/' + name + '-js-ok")</script>'
        machine.succeed("printf %s " + shlex.quote(page) + " > /tmp/browser-fixtures/" + name + ".html")
    machine.succeed("systemd-run --unit=browser-fixtures python3 -m http.server 8000 --bind 127.0.0.1 --directory /tmp/browser-fixtures")
    machine.wait_for_open_port(8000)
    browsers = [
        ("chrome", "google-chrome", "Google-chrome"),
        ("chromium", "chromium", "Chromium"),
        ("firefox", "firefox", "firefox"),
        ("helium", "/opt/helium/helium", "helium"),
    ]
    for name, binary, window_class in browsers:
        with subtest(name + " page load and JavaScript"):
            print(machine.succeed(binary + " --version"))
            url = "http://127.0.0.1:8000/" + name + ".html"
            if name == "firefox":
                machine.succeed("install -d -o alice -g users /home/alice/firefox-profile")
                command = binary + " --no-remote --profile /home/alice/firefox-profile " + url
            else:
                command = binary + " --no-first-run --no-default-browser-check --user-data-dir=/home/alice/" + name + "-profile " + url
            launch(name, command, window_class)
            machine.wait_until_succeeds("DISPLAY=:0 xdotool search --onlyvisible --name " + shlex.quote("Omnix browser check " + name))
            machine.wait_until_succeeds("journalctl -u browser-fixtures --no-pager | grep -q " + name + "-js-ok")
            evidence(name)
  '';

  communication = mkTest "communication" [ unfreePkgs.discord pkgs.element-desktop pkgs.thunderbird pkgs.gnome-keyring ] ''
    clients = [
        ("discord", "discord", "discord"),
        ("element", "${elementLaunch}", "element"),
        ("thunderbird", "thunderbird", "thunderbird"),
    ]
    for name, command, window_class in clients:
        with subtest(name + " unprivileged desktop startup"):
            launch(name, command, window_class)
            evidence(name)
    print("Scope: desktop startup only; no external account, messages, calls or mail delivery.")
  '';
}

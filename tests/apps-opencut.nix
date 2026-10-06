# OpenCut on the Omnix base. OpenCut publishes no Linux binary, AppImage or
# flake, and nixpkgs has no package: its GitHub releases are tags of a
# Next.js web app (v0.3.0 is the "classic" editor that opencut.app runs).
# So this builds the web app from the upstream v0.3.0 source, serves it
# with its own Next.js standalone server inside the VM (no network), and
# opens the editor in Brave's official Linux build in the X11 session.
{ pkgs, module }:
let
  version = "0.3.0";
  src = pkgs.fetchFromGitHub {
    owner = "OpenCut-app";
    repo = "OpenCut";
    rev = "v${version}"; # f4bd689f51cf12a4dd0a32f602f761be314d9686
    hash = "sha256-QiRCe53Rv/321VFL5uK3c4UE9d920YMrWQh+eupUuhk=";
  };

  # bun install, pinned by output hash (fixed-output, so it may download).
  # --ignore-scripts: nothing in the tree needs an install script to build.
  deps = pkgs.stdenvNoCC.mkDerivation {
    pname = "opencut-node-modules";
    inherit version src;
    nativeBuildInputs = [ pkgs.bun pkgs.cacert ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      export HOME=$TMPDIR
      bun install --ignore-scripts --no-progress --linker=hoisted
    '';
    installPhase = ''
      mkdir -p $out
      cp -a node_modules $out/
      if [ -d apps/web/node_modules ]; then
        mkdir -p $out/web && cp -a apps/web/node_modules $out/web/
      fi
    '';
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-PMnY8nz/HwHPhvK+/uXTaDm0UKm6ZszUIVLYuhHYo5s=";
  };

  # The upstream .env.example values: placeholders for the optional services
  # (Postgres, Redis, Freesound, ...) whose presence the server validates.
  # The editor itself keeps projects in the browser and needs none of them.
  envExample = ''
    NEXT_PUBLIC_SITE_URL=http://localhost:3000
    NEXT_PUBLIC_MARBLE_API_URL=https://api.marblecms.com
    DATABASE_URL=postgresql://opencut:opencut@localhost:5432/opencut
    BETTER_AUTH_SECRET=your_better_auth_secret
    UPSTASH_REDIS_REST_URL=http://localhost:8079
    UPSTASH_REDIS_REST_TOKEN=example_token
    MARBLE_WORKSPACE_KEY=your_workspace_key_here
    FREESOUND_CLIENT_ID=your_client_id_here
    FREESOUND_API_KEY=your_api_key_here
  '';
  envFile = pkgs.writeText "opencut.env" envExample;

  # next/font/google downloads Inter at build time; the Nix sandbox has no
  # network, so answer with Next's own mock hook (NEXT_FONT_GOOGLE_MOCKED_
  # RESPONSES) for the CSS, and serve the nixpkgs Inter font file on
  # localhost for Turbopack to download.
  fontMock = pkgs.writeText "font-mock.js" ''
    const css = `@font-face {
      font-family: 'Inter';
      font-style: normal;
      font-weight: 100 900;
      font-display: swap;
      src: url(http://127.0.0.1:8735/InterVariable.ttf) format('truetype');
    }`;
    module.exports = {
      "https://fonts.googleapis.com/css2?family=Inter:wght@100..900&display=swap": css,
    };
  '';

  opencut = pkgs.stdenv.mkDerivation {
    pname = "opencut-web";
    inherit version src;
    nativeBuildInputs = [ pkgs.nodejs_22 pkgs.python3 pkgs.autoPatchelfHook pkgs.makeWrapper ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontConfigure = true;
    buildPhase = ''
      export HOME=$TMPDIR NEXT_TELEMETRY_DISABLED=1
      cp -a ${deps}/node_modules node_modules
      if [ -d ${deps}/web/node_modules ]; then cp -a ${deps}/web/node_modules apps/web/; fi
      chmod -R u+w node_modules apps/web
      patchShebangs node_modules
      set -a; . ${envFile}; set +a
      export NODE_ENV=production NEXT_FONT_GOOGLE_MOCKED_RESPONSES=${fontMock}
      python3 -m http.server 8735 --bind 127.0.0.1 -d ${pkgs.inter}/share/fonts/truetype &
      fontServer=$!
      cd apps/web
      node ../../node_modules/next/dist/bin/next build
      kill $fontServer
    '';
    installPhase = ''
      mkdir -p $out/share/opencut $out/bin
      cp -a .next/standalone/. $out/share/opencut/
      cp -a public $out/share/opencut/apps/web/
      cp -a .next/static $out/share/opencut/apps/web/.next/
      # glibc system: drop the musl builds of the native modules.
      rm -rf $out/share/opencut/node_modules/@img/*musl*
      makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/opencut-web \
        --add-flags $out/share/opencut/apps/web/server.js \
        --set-default NODE_ENV production \
        --set-default PORT 3000 \
        --set-default HOSTNAME 127.0.0.1
    '';
  };

  # Hash matches brave-browser-1.96.61-linux-amd64.zip.sha256 from the release.
  brave = pkgs.fetchurl {
    url = "https://github.com/brave/brave-browser/releases/download/v1.96.61/brave-browser-1.96.61-linux-amd64.zip";
    sha256 = "c68cf179603470e8001a949294fe98b593f0749ca95f42687d855081b1c394a4";
  };
in
pkgs.testers.runNixOSTest {
  name = "omnix-app-opencut";
  nodes.machine = {
    imports = [ module "${pkgs.path}/nixos/tests/common/x11.nix" ];
    omnix.fhs.presets.desktop = true;
    environment.systemPackages = [ opencut pkgs.unzip pkgs.xdotool pkgs.curl ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    # OpenCut shows a "Desktop only" gate below a 1024 px wide viewport; the
    # default 1024x768 screen minus Brave's side panel is narrower than that.
    virtualisation.resolution = { x = 1280; y = 800; };
  };
  enableOCR = true;
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("omnix-ldconfig.service")
    machine.wait_for_x()

    with subtest("OpenCut's Next.js server starts"):
        machine.succeed("systemd-run --unit=opencut-web -p EnvironmentFile=${envFile} -E HOSTNAME=127.0.0.1 -E PORT=3000 opencut-web")
        machine.wait_for_open_port(3000)
        machine.succeed("curl -fsS http://127.0.0.1:3000/projects | grep -q OpenCut")
        print(machine.succeed("journalctl -u opencut-web --no-pager | tail -n 20"))

    machine.succeed("mkdir -p /opt/brave && unzip -q ${brave} -d /opt/brave")

    with subtest("the editor opens in Brave"):
        # An unknown project id makes the editor create a new project and
        # redirect to it (EditorProvider), the same as "New project".
        # The editor's renderer (opencut-wasm) needs WebGPU or WebGL2 and the
        # VM has no GPU: without software GL (--use-angle=swiftshader
        # --enable-unsafe-swiftshader) it stops at "Failed to load project".
        machine.succeed(
            "systemd-run --unit=brave -E DISPLAY=:0 -E HOME=/root"
            " /opt/brave/brave --no-sandbox --user-data-dir=/root/brave-profile --no-first-run"
            " --start-maximized --remote-debugging-port=9222 --enable-logging=stderr --use-angle=swiftshader --enable-unsafe-swiftshader"
            " http://127.0.0.1:3000/editor/omnix-test"
        )
        machine.wait_until_succeeds("DISPLAY=:0 xdotool search --onlyvisible --class brave", timeout=180)
        machine.succeed("sleep 30")
        machine.succeed("systemctl is-active brave opencut-web")
        print("window: " + machine.succeed("DISPLAY=:0 xdotool search --onlyvisible --class brave getwindowname %@"))
        tabs = machine.succeed("curl -fsS http://127.0.0.1:9222/json/list")
        print(tabs)
        # Redirected to a freshly created project: /editor/<uuid>.
        import re
        assert re.search(r'"url": "http://127.0.0.1:3000/editor/[0-9a-f]{8}-[0-9a-f-]{27}"', tabs), "no new project"
        print(machine.succeed("journalctl -u brave --no-pager | grep CONSOLE | tail -n 20"))
        machine.screenshot("opencut-welcome")
        welcome = machine.get_screen_text()
        print("screen text: " + welcome)
        assert "Welcome to OpenCut" in welcome

    with subtest("the editor UI is visible"):
        # Dismiss the welcome dialog.
        machine.succeed("DISPLAY=:0 xdotool key Escape")
        machine.succeed("sleep 3")
        machine.succeed("systemctl is-active brave opencut-web")
        machine.screenshot("opencut")
        text = machine.get_screen_text()
        print("screen text: " + text)
        assert "Failed to load project" not in text
        assert "Untitled Project" in text
  '';
}

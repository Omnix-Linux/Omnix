# Boots NixOS with the Omnix base and runs unmodified foreign binaries: the
# booted-VM half of roadmap Phase 0 (real envfs, real activation and switch).
{ pkgs, module }:
let
  # The VM has no network: foreign binaries arrive as fixed-output fetches.
  node = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v22.12.0/node-v22.12.0-linux-x64.tar.xz";
    hash = "sha256-IpgiNeG3H6iFD4Lt0Jza5+PzLfF2Sp7CmMctJe8sFk8=";
  };
  python = pkgs.fetchurl {
    url = "https://github.com/astral-sh/python-build-standalone/releases/download/20241206/cpython-3.12.8%2B20241206-x86_64-unknown-linux-gnu-install_only.tar.gz";
    hash = "sha256-udbuXdrBGY5y1TESaYdz/Iu1l94JVZLrhJynlDBmmbo=";
  };
in
pkgs.testers.runNixOSTest {
  name = "omnix-fhs";
  nodes.machine = {
    imports = [ module ];
    environment.systemPackages = [ pkgs.gnutar pkgs.xz pkgs.gzip ];
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("omnix-ldconfig.service")

    with subtest("standard paths exist"):
        machine.succeed("test -e /lib64/ld-linux-x86-64.so.2")
        machine.succeed("test -e /usr/lib/libz.so.1 -a -e /lib/libstdc++.so.6")
        machine.succeed("test -e /usr/lib/libxml2.so.2 -a -e /usr/lib/libcrypt.so.1")

    machine.succeed("mkdir -p /opt/node /opt/python")
    machine.succeed("tar -xJf ${node} -C /opt/node --strip-components=1")
    machine.succeed("tar -xzf ${python} -C /opt/python --strip-components=1")

    with subtest("unmodified foreign binaries run"):
        machine.succeed("/opt/node/bin/node -e 'require(\"zlib\").gzipSync(\"x\")'")
        machine.succeed("/opt/python/bin/python3 -c 'import ssl, sqlite3, ctypes'")

    with subtest("a service without nix-ld's session variables"):
        machine.succeed("systemd-run --wait --pipe /opt/node/bin/node -e 'console.log(1)'")

    with subtest("ldconfig and find_library"):
        machine.succeed("/sbin/ldconfig -p | grep -q 'libz.so.1 .*=> /usr/lib/libz.so.1'")
        machine.succeed(
            "/opt/python/bin/python3 -c 'import ctypes.util as c; assert c.find_library(\"z\")'"
        )

    with subtest("envfs resolves shebangs and /bin paths on PATH"):
        machine.succeed("/bin/true")
        machine.succeed("printf '#!/usr/bin/python3\\nprint(1)\\n' > /tmp/s.py && chmod +x /tmp/s.py")
        # A relocatable interpreter (this python-build-standalone) finds its stdlib
        # by readlinking the path it was started as. Stock envfs doesn't resolve
        # names on readlink; Omnix's envfs carries the fix (Mic92/envfs#233).
        machine.succeed("PATH=/opt/python/bin:$PATH /tmp/s.py | grep -qx 1")
        # An interpreter with a compiled-in prefix works today.
        machine.succeed("printf '#!/usr/bin/bash\\necho ok\\n' > /tmp/s.sh && chmod +x /tmp/s.sh && /tmp/s.sh")

    with subtest("timezones resolve through /etc/zoneinfo"):
        machine.succeed("/opt/python/bin/python3 -c 'import zoneinfo; zoneinfo.ZoneInfo(\"Europe/Moscow\")'")
  '';
}

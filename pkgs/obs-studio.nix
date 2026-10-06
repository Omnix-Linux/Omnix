# OBS Studio with Omnix's own fixes. Each fix lives as a commit on the
# Omnix-Linux/obs-studio fork, branch omnix/<version> (the upstream release plus
# our commits), and is proposed upstream; it is applied here until OBS ships it.
#
#   5218ef9  Guard against a freed core on shutdown in 3 sites
#            (obsproject/obs-studio#13906): obs_enter_graphics() dereferenced
#            the freed core when a preview, multiview or screenshot destructor
#            ran after obs_shutdown(), crashing OBS on exit.
#
# When nixpkgs moves to a new OBS release, rebase the fork branch onto it and
# update the commit below; the version check stops a stale patch going unnoticed.
{ lib, obs-studio, fetchpatch }:

assert lib.assertMsg (obs-studio.version == "32.2.2")
  "pkgs/obs-studio.nix: nixpkgs now has OBS ${obs-studio.version}; rebase Omnix-Linux/obs-studio omnix/<version> and update the patch.";

obs-studio.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    (fetchpatch {
      name = "obs-guard-freed-core-on-shutdown.patch";
      url = "https://github.com/Omnix-Linux/obs-studio/commit/5218ef9f2c3834c2f27fbc979365867565e447e1.patch";
      hash = "sha256-VJPXpIqqJQewY2HHMWiNtZgLyPfDbvR/9qbH47y0VGY=";
    })
  ];
})

# OBS Studio built from Omnix's fork: omnix-apps/obs-studio `master` is upstream
# master plus Omnix's own fixes (each proposed upstream), synced from time to time.
# nixpkgs' obs-studio recipe builds it; only the source and version change.
#
# Omnix's commits on master:
#   ab9ca05  Guard against a freed core on shutdown in 3 sites
#            (obsproject/obs-studio#13906): obs_enter_graphics() dereferenced
#            the freed core when a preview, multiview or screenshot destructor
#            ran after obs_shutdown(), crashing OBS on exit.
#   cb73236  Allow absolute core module paths on Linux: OBS 33's core module
#            loader prefixed "<exe>/../" to OBS_PLUGIN_PATH, which Nix builds
#            as an absolute path, so no core modules loaded at all.
#
# To sync: `gh repo sync omnix-apps/obs-studio --source obsproject/obs-studio`
# can't fast-forward past our commits, so rebase them onto upstream master and
# push; then set `rev` to the new master head and update `hash` and `version`.
{ lib, obs-studio, fetchFromGitHub }:

let
  rev = "cb7323695215aa0e3a190b45afca257a9029dca8";
  # `git describe` of upstream's last tag before `rev`, plus the commit date.
  version = "33.0.0-beta6-unstable-2026-10-06";
in
obs-studio.overrideAttrs (old: {
  inherit version;
  src = fetchFromGitHub {
    owner = "omnix-apps";
    repo = "obs-studio";
    inherit rev;
    fetchSubmodules = true;
    hash = "sha256-RBMWZPwU+u3RT12p8ufUsEPhZGzuj+RBB7A53tkprdo=";
  };
  # nixpkgs' fix-nix-plugin-path.patch edits the plugin search list that upstream
  # master replaced with a core module loader; the fork's cb73236 makes that loader
  # accept Nix's absolute paths instead. The OBS VM test checks the modules load.
  patches = [ ];
  # OBS 33 moved core modules from lib/obs-plugins to lib/obs-modules/core
  # ("cmake: Change name of core module output directory"); point nixpkgs' CEF
  # cleanup and relinking at the new directory.
  preFixup = lib.replaceStrings [ "lib/obs-plugins" ] [ "lib/obs-modules/core" ] (old.preFixup or "");
  postFixup = lib.replaceStrings [ "lib/obs-plugins" ] [ "lib/obs-modules/core" ] (old.postFixup or "");
  cmakeFlags = map
    (f: if lib.hasPrefix "-DOBS_VERSION_OVERRIDE=" f then "-DOBS_VERSION_OVERRIDE=${version}" else f)
    old.cmakeFlags;
})

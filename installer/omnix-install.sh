#!/usr/bin/env bash
# Omnix installer (design §7): network, disk, flavor, user, then nixos-install.
#
# Every answer can come from the environment instead of a prompt, which is how
# the installer is tested unattended:
#   OMNIX_DISK OMNIX_FS OMNIX_LUKS OMNIX_FLAVOR OMNIX_USER OMNIX_PASSWORD
#   OMNIX_HOSTNAME OMNIX_TIMEZONE OMNIX_YES=1 (skip the wipe confirmation)
set -euo pipefail
# Unset answers are asked for below.
OMNIX_DISK=${OMNIX_DISK:-} OMNIX_FS=${OMNIX_FS:-} OMNIX_LUKS=${OMNIX_LUKS:-}
OMNIX_FLAVOR=${OMNIX_FLAVOR:-} OMNIX_USER=${OMNIX_USER:-} OMNIX_PASSWORD=${OMNIX_PASSWORD:-}
OMNIX_HOSTNAME=${OMNIX_HOSTNAME:-} OMNIX_TIMEZONE=${OMNIX_TIMEZONE:-} OMNIX_YES=${OMNIX_YES:-}
ETC=/etc/omnix
NIXPKGS_REV=$(cat $ETC/nixpkgs-rev)
MNT=/mnt

die() { gum style --foreground 1 "omnix-install: $*" >&2; exit 1; }
ask() { # var, prompt, [default]
  local current=${!1:-}
  [ -n "$current" ] && return
  printf -v "$1" '%s' "$(gum input --header "$2" --value "${3:-}")"
}
choose() { # var, header, options...
  local var=$1 header=$2; shift 2
  [ -n "${!var:-}" ] && return
  printf -v "$var" '%s' "$(gum choose --header "$header" "$@")"
}

[ "$(id -u)" = 0 ] || die "run as root (sudo omnix-install)"
gum style --border rounded --padding "0 2" --bold "Omnix installer"

# 1. Network: everything after this downloads from cache.nixos.org. Give a
# wired link up to a minute for DHCP before asking.
online() { curl -fsS --max-time 5 -o /dev/null https://cache.nixos.org/nix-cache-info; }
for _ in $(seq 30); do online && break; sleep 2; done
until online; do
  [ -n "${OMNIX_YES:-}" ] && die "no network"
  gum confirm "No network. Open nmtui to connect?" || die "a network is required"
  nmtui
done

# 2. Disk: the whole chosen disk; v1 has no dual-boot.
mapfile -t disks < <(lsblk -dpno NAME,SIZE,MODEL -e 1,7,11 | sed 's/  */ /g')
[ ${#disks[@]} -gt 0 ] || die "no disks found"
if [ -z "${OMNIX_DISK:-}" ]; then
  OMNIX_DISK=$(gum choose --header "Install to which disk? (it will be ERASED)" "${disks[@]}" | cut -d' ' -f1)
fi
choose OMNIX_FS "Filesystem" ext4 btrfs xfs
case $OMNIX_FS in ext4 | btrfs | xfs) ;; *) die "unknown filesystem $OMNIX_FS" ;; esac
if [ -z "${OMNIX_LUKS:-}" ]; then
  gum confirm "Encrypt the disk (LUKS)?" --default=false && OMNIX_LUKS=1 || OMNIX_LUKS=0
fi
EFI=false; [ -d /sys/firmware/efi ] && EFI=true

# 3. Flavor: the live registry, so a new flavor needs no new ISO; the ISO's
# own copy if GitHub is unreachable. Only ready entries are offered.
REGISTRY=/tmp/omnix-flavors.json
if ! curl -fsS --max-time 10 -o $REGISTRY https://raw.githubusercontent.com/Omnix-Linux/Omnix/main/flavors.json \
  || ! jq -e 'type == "array"' $REGISTRY >/dev/null; then
  cp $ETC/flavors.json $REGISTRY
fi
mapfile -t flavors < <(jq -r '.[] | select(.status == "ready") | "\(.name) — \(.description)"' $REGISTRY)
[ ${#flavors[@]} -gt 0 ] || die "the flavor registry has no ready flavors"
if [ -z "${OMNIX_FLAVOR:-}" ]; then
  selected_flavor=$(printf '%s\n' "${flavors[@]}" | gum choose --header "What kind of system do you want?")
  OMNIX_FLAVOR=$(jq -r --arg choice "$selected_flavor" \
    '.[] | select(.status == "ready" and "\(.name) — \(.description)" == $choice) | .id' $REGISTRY)
fi
flavor_json=$(jq -c --arg id "$OMNIX_FLAVOR" '.[] | select(.id == $id and .status == "ready")' $REGISTRY)
[ -n "$flavor_json" ] || die "unknown or unready flavor $OMNIX_FLAVOR"
flavor_name=$(jq -r '.name' <<<"$flavor_json")
flavor_flake=$(jq -r '.flake // empty' <<<"$flavor_json")
flavor_module=$(jq -r '.module // empty' <<<"$flavor_json")

# 4. User.
ask OMNIX_USER "Username"
[[ $OMNIX_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username $OMNIX_USER"
if [ -z "${OMNIX_PASSWORD:-}" ]; then
  OMNIX_PASSWORD=$(gum input --password --header "Password for $OMNIX_USER")
  [ "$OMNIX_PASSWORD" = "$(gum input --password --header "Again")" ] || die "passwords differ"
fi
ask OMNIX_HOSTNAME "Hostname" omnix
ask OMNIX_TIMEZONE "Timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

if [ -z "${OMNIX_YES:-}" ]; then
  gum confirm "Erase $OMNIX_DISK and install Omnix ($flavor_name, $OMNIX_FS$([ "$OMNIX_LUKS" = 1 ] && echo ", encrypted"))?" || die "cancelled"
fi

# Partition, format and mount with disko.
luks=false; [ "$OMNIX_LUKS" = 1 ] && luks=true
cat > /tmp/omnix-disk.nix <<NIX
import $ETC/disk-layout.nix { device = "$OMNIX_DISK"; fs = "$OMNIX_FS"; luks = $luks; efi = $EFI; }
NIX
disko --mode destroy,format,mount --yes-wipe-all-disks /tmp/omnix-disk.nix

# 5. Hardware, and the machine flake the user owns.
nixos-generate-config --root $MNT
D=$MNT/etc/nixos
rm -f $D/configuration.nix
nvidia=false; lspci 2>/dev/null | grep -qi 'vga.*nvidia\|3d.*nvidia' && nvidia=true
sed -e "s|@HOSTNAME@|$OMNIX_HOSTNAME|" -e "s|@TIMEZONE@|$OMNIX_TIMEZONE|" \
  -e "s|@USER@|$OMNIX_USER|" -e "s|@EFI@|$EFI|" -e "s|@DISK@|$OMNIX_DISK|" \
  -e "s|@NVIDIA@|$nvidia|" $ETC/local.nix > $D/local.nix
if [ -n "$flavor_flake" ]; then
  flavor_input="flavor = { url = \"$flavor_flake\"; inputs.nixpkgs.follows = \"nixpkgs\"; inputs.omnix.follows = \"omnix\"; };"
  flavor_args="flavor, "
  flavor_modules="flavor.nixosModules.$flavor_module"
else
  flavor_input="" flavor_args="" flavor_modules=""
fi
sed -e "s|@FLAVOR_INPUT@|$flavor_input|" -e "s|@FLAVOR_ARGS@|$flavor_args|" \
  -e "s|@FLAVOR_MODULES@|$flavor_modules|" $ETC/flake.nix > $D/flake.nix
# Lock nixpkgs to the ISO's own revision: the versions the ISO was built and
# tested with, all on cache.nixos.org.
(cd $D && nix --extra-experimental-features 'nix-command flakes' flake lock \
  --override-input nixpkgs "github:NixOS/nixpkgs/$NIXPKGS_REV")

# 6. Install.
nixos-install --root $MNT --flake "$D#omnix" --no-root-passwd
echo "$OMNIX_USER:$OMNIX_PASSWORD" | nixos-enter --root $MNT -c chpasswd
gum style --foreground 2 "Omnix is installed. Reboot when ready."

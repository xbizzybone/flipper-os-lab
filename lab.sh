#!/usr/bin/env bash
#
# flipper-os-lab — local PoC for the Flipper OS storage architecture RFC
#
# Reproduces Phase-0 of the RFC entirely on loop-backed disk images:
#   - immutable base  : squashfs + dm-verity (read-only lower)
#   - profiles        : Btrfs subvolumes (overlay upperdirs), clone/reset via snapshots
#   - /data           : separate persistent partition, bind-mounted into the merged root
#   - "boot <id>"     : assembles the OverlayFS exactly like the initramfs would
#
# No RK3576 board required. Runs on any Linux host with root.
#
# Usage:  sudo ./lab.sh <command>
#   deps                 check required tools
#   build                build the read-only base (squashfs + dm-verity)
#   init                 create loop disks: profiles pool (Btrfs) + /data
#   profile list
#   profile create <id>
#   profile clone  <id> <new>
#   profile reset  <id>
#   boot <id>            assemble + mount the overlay for profile <id>
#   shell <id>           boot <id> and chroot into it (needs busybox in base)
#   status               show mounts / loops / dm / subvolumes
#   demo                 narrated end-to-end walkthrough
#   teardown             unmount everything, detach loops, remove dm devices
#
# Env toggles:
#   LAB_ROOT=<dir>       where runtime artifacts live (default: ./run)
#   NOVERITY=1           skip dm-verity (plain ro squashfs) — use if your
#                        kernel lacks CONFIG_DM_VERITY (e.g. some WSL2 kernels)
#
set -euo pipefail

# ---------------------------------------------------------------- config ----
LAB_ROOT="${LAB_ROOT:-$PWD/run}"
NOVERITY="${NOVERITY:-0}"

BASE_ROOTFS="$LAB_ROOT/base-rootfs"
BASE_IMG="$LAB_ROOT/base.squashfs"
VERITY_HASH="$LAB_ROOT/base.verity"
VERITY_ROOTHASH="$LAB_ROOT/base.roothash"
PROFILES_IMG="$LAB_ROOT/profiles.btrfs"
DATA_IMG="$LAB_ROOT/data.ext4"

MNT="$LAB_ROOT/mnt"
BASE_MNT="$MNT/base"          # read-only base (verity) lower
POOL_MNT="$MNT/profiles"      # Btrfs pool holding per-profile subvolumes
DATA_MNT="$MNT/data"          # persistent /data
ROOT_MNT="$MNT/root"          # merged overlay = the "booted" system

DM_BASE="flab_base"
BASE_VERSION="1.4.0"          # base_min_version guard reference

# --------------------------------------------------------------- helpers ----
c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_rst=$'\033[0m'
log()  { echo "${c_blue}::${c_rst} $*"; }
ok()   { echo "${c_grn}ok${c_rst} $*"; }
warn() { echo "${c_yel}!!${c_rst} $*" >&2; }
die()  { echo "${c_red}xx${c_rst} $*" >&2; exit 1; }
step() { echo; echo "${c_blue}========== $* ==========${c_rst}"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo ./lab.sh $*)"; }
is_mounted() { mountpoint -q "$1"; }

# ----------------------------------------------------------------- deps -----
cmd_deps() {
  step "Checking dependencies"
  local missing=0
  declare -A pkg=(
    [mksquashfs]=squashfs-tools [veritysetup]=cryptsetup
    [mkfs.btrfs]=btrfs-progs    [btrfs]=btrfs-progs
    [mkfs.ext4]=e2fsprogs       [losetup]=util-linux
  )
  for bin in mksquashfs veritysetup mkfs.btrfs btrfs mkfs.ext4 losetup; do
    if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else warn "MISSING $bin (apt pkg: ${pkg[$bin]})"; missing=1; fi
  done
  echo
  if [ "$missing" -eq 1 ]; then
    echo "Install on Debian/Ubuntu:"
    echo "  sudo apt-get update && sudo apt-get install -y squashfs-tools cryptsetup btrfs-progs e2fsprogs util-linux"
    die "missing dependencies"
  fi
  # kernel module sanity (best effort)
  for mod in overlay squashfs btrfs dm_verity; do
    if modprobe "$mod" 2>/dev/null || grep -qw "$mod" /proc/filesystems 2>/dev/null || lsmod 2>/dev/null | grep -qw "$mod"; then
      ok "kernel: $mod"
    else
      warn "kernel module '$mod' not obviously available"
      [ "$mod" = dm_verity ] && warn "  -> if dm-verity is unavailable, run with NOVERITY=1"
    fi
  done
  ok "dependencies satisfied"
}

# -------------------------------------------------------------- build -------
cmd_build() {
  need_root build
  step "Building read-only base (squashfs + dm-verity)"
  rm -rf "$BASE_ROOTFS"
  mkdir -p "$BASE_ROOTFS"/{usr/bin,usr/lib,etc/flipper,etc/systemd/network,etc/systemd/system,home,data,var}

  # A minimal, stateless base. /usr is the OS, /etc holds vendor defaults only.
  cat > "$BASE_ROOTFS/etc/os-release" <<EOF
NAME="Flipper OS (lab)"
ID=flipper-os
VERSION_ID=$BASE_VERSION
PRETTY_NAME="Flipper OS lab base $BASE_VERSION"
EOF
  echo "$BASE_VERSION" > "$BASE_ROOTFS/usr/lib/flipper-base.version"
  # A base-owned default config. Profiles must NEVER shadow this file; they add
  # drop-ins under *.d/ instead (this is the RFC's anti-drift rule).
  cat > "$BASE_ROOTFS/etc/flipper/base.conf" <<EOF
# base.conf — shipped by the immutable base, read-only.
hostname = flipper-lab
log_level = info
EOF
  mkdir -p "$BASE_ROOTFS/etc/flipper/conf.d"   # drop-in dir profiles may write to
  echo "I am the immutable base. You cannot write here." > "$BASE_ROOTFS/etc/flipper/README"

  # Optional: drop in busybox so 'shell <id>' can chroot into the merged root.
  if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$BASE_ROOTFS/usr/bin/busybox"
    ln -sf busybox "$BASE_ROOTFS/usr/bin/sh"
    ln -sf busybox "$BASE_ROOTFS/usr/bin/ls"
    ln -sf busybox "$BASE_ROOTFS/usr/bin/cat"
    mkdir -p "$BASE_ROOTFS/bin"; ln -sf ../usr/bin/sh "$BASE_ROOTFS/bin/sh"
    ok "busybox embedded (chroot demo available via 'shell')"
  else
    warn "busybox not found on host — 'shell' will be limited; install busybox-static for chroot demo"
  fi

  mkdir -p "$LAB_ROOT"
  rm -f "$BASE_IMG" "$VERITY_HASH" "$VERITY_ROOTHASH"
  mksquashfs "$BASE_ROOTFS" "$BASE_IMG" -comp zstd -noappend -quiet
  ok "squashfs: $BASE_IMG ($(du -h "$BASE_IMG" | cut -f1))"

  if [ "$NOVERITY" = "1" ]; then
    warn "NOVERITY=1 — skipping dm-verity hash generation"
  else
    veritysetup format "$BASE_IMG" "$VERITY_HASH" | awk '/Root hash/{print $NF}' > "$VERITY_ROOTHASH"
    ok "dm-verity root hash: $(cat "$VERITY_ROOTHASH")"
  fi
  ok "base built"
}

# --------------------------------------------------------------- init -------
cmd_init() {
  need_root init
  step "Initialising storage (profiles pool + /data)"
  mkdir -p "$BASE_MNT" "$POOL_MNT" "$DATA_MNT" "$ROOT_MNT"

  [ -f "$PROFILES_IMG" ] || { truncate -s 2G "$PROFILES_IMG"; mkfs.btrfs -q -f "$PROFILES_IMG"; }
  [ -f "$DATA_IMG" ]     || { truncate -s 512M "$DATA_IMG"; mkfs.ext4 -q -F "$DATA_IMG"; }

  is_mounted "$POOL_MNT" || mount -o loop "$PROFILES_IMG" "$POOL_MNT"
  is_mounted "$DATA_MNT" || mount -o loop "$DATA_IMG" "$DATA_MNT"

  mkdir -p "$POOL_MNT/.work" "$POOL_MNT/.pristine"
  # Seed /data: this is what MUST survive both profile reset AND base A/B swap.
  mkdir -p "$DATA_MNT/home" "$DATA_MNT/captures"
  [ -f "$DATA_MNT/persistent.marker" ] || echo "created $(date -Is)" > "$DATA_MNT/persistent.marker"

  ok "profiles pool mounted at $POOL_MNT (Btrfs)"
  ok "/data mounted at $DATA_MNT (persistent)"
}

# ------------------------------------------------------- base open/close ----
open_base() {
  is_mounted "$BASE_MNT" && return 0
  if [ "$NOVERITY" = "1" ]; then
    mount -o ro,loop "$BASE_IMG" "$BASE_MNT"
  else
    [ -f "$VERITY_ROOTHASH" ] || die "no verity root hash — run 'build' first (or NOVERITY=1)"
    veritysetup status "$DM_BASE" >/dev/null 2>&1 || \
      veritysetup open "$BASE_IMG" "$DM_BASE" "$VERITY_HASH" "$(cat "$VERITY_ROOTHASH")"
    mount -o ro "/dev/mapper/$DM_BASE" "$BASE_MNT"
  fi
}
close_base() {
  is_mounted "$BASE_MNT" && umount "$BASE_MNT" || true
  [ "$NOVERITY" = "1" ] || veritysetup close "$DM_BASE" 2>/dev/null || true
}

# ------------------------------------------------------------- profile ------
profile_exists() { btrfs subvolume show "$POOL_MNT/$1" >/dev/null 2>&1; }

profile_create() {
  need_root profile
  local id="$1"; [ -n "$id" ] || die "usage: profile create <id>"
  is_mounted "$POOL_MNT" || die "run 'init' first"
  profile_exists "$id" && die "profile '$id' already exists"

  btrfs subvolume create "$POOL_MNT/$id" >/dev/null
  # Profile config lives ONLY in drop-in dirs — never shadows a base file.
  mkdir -p "$POOL_MNT/$id/etc/flipper/conf.d" "$POOL_MNT/$id/etc/systemd/network"
  cat > "$POOL_MNT/$id/etc/flipper/conf.d/10-$id.conf" <<EOF
# drop-in added by profile '$id' (overlay upper, writable)
profile = $id
EOF
  cat > "$POOL_MNT/$id/profile.toml" <<EOF
[profile]
id = "$id"
base_min_version = "$BASE_VERSION"
EOF
  mkdir -p "$POOL_MNT/.work/$id"
  # Pristine read-only snapshot — 'reset' restores from this.
  btrfs subvolume snapshot -r "$POOL_MNT/$id" "$POOL_MNT/.pristine/$id" >/dev/null
  ok "profile '$id' created (+ pristine snapshot)"
}

profile_clone() {
  need_root profile
  local src="$1" dst="$2"; [ -n "$src" ] && [ -n "$dst" ] || die "usage: profile clone <id> <new>"
  profile_exists "$src" || die "no such profile '$src'"
  profile_exists "$dst" && die "'$dst' already exists"
  # Instant copy-on-write clone (this is the cheap reflink/snapshot the RFC promises).
  btrfs subvolume snapshot "$POOL_MNT/$src" "$POOL_MNT/$dst" >/dev/null
  btrfs subvolume snapshot -r "$POOL_MNT/$dst" "$POOL_MNT/.pristine/$dst" >/dev/null
  mkdir -p "$POOL_MNT/.work/$dst"
  ok "cloned '$src' -> '$dst' (copy-on-write, O(metadata))"
}

profile_reset() {
  need_root profile
  local id="$1"; [ -n "$id" ] || die "usage: profile reset <id>"
  [ -d "$POOL_MNT/.pristine/$id" ] || die "no pristine snapshot for '$id'"
  # If this profile is currently 'booted', tear the overlay down first.
  is_mounted "$ROOT_MNT" && unmount_root
  btrfs subvolume delete "$POOL_MNT/$id" >/dev/null
  btrfs subvolume snapshot "$POOL_MNT/.pristine/$id" "$POOL_MNT/$id" >/dev/null
  rm -rf "$POOL_MNT/.work/$id"; mkdir -p "$POOL_MNT/.work/$id"
  ok "profile '$id' reset to pristine"
}

profile_list() {
  is_mounted "$POOL_MNT" || die "run 'init' first"
  step "Profiles"
  for d in "$POOL_MNT"/*/; do
    id="$(basename "$d")"
    case "$id" in .work|.pristine) continue;; esac
    [ -f "$POOL_MNT/$id/profile.toml" ] && echo "  - $id"
  done
}

# ---------------------------------------------------------------- boot ------
unmount_root() {
  if is_mounted "$ROOT_MNT"; then
    # unmount any /data binds first
    for sub in home data captures; do
      is_mounted "$ROOT_MNT/$sub" && umount "$ROOT_MNT/$sub" || true
    done
    umount "$ROOT_MNT" || true
  fi
}

cmd_boot() {
  need_root boot
  local id="$1"; [ -n "$id" ] || die "usage: boot <id>"
  profile_exists "$id" || die "no such profile '$id' (create it first)"
  is_mounted "$POOL_MNT" || die "run 'init' first"

  # base_min_version guard (RFC anti-corruption check)
  local need; need="$(awk -F'\"' '/base_min_version/{print $2}' "$POOL_MNT/$id/profile.toml" 2>/dev/null || true)"
  if [ -n "$need" ] && [ "$need" != "$BASE_VERSION" ]; then
    die "profile '$id' needs base $need but base is $BASE_VERSION (would refuse to mount)"
  fi

  step "Booting profile '$id'  (initramfs equivalent of: flipper.profile=$id)"
  unmount_root
  open_base
  # THE core step: assemble the OverlayFS just like the initramfs would.
  mount -t overlay overlay \
    -o "lowerdir=$BASE_MNT,upperdir=$POOL_MNT/$id,workdir=$POOL_MNT/.work/$id" \
    "$ROOT_MNT"
  # Bind persistent /data into known paths so it survives reset + A/B swaps.
  mkdir -p "$ROOT_MNT/data"
  mount --bind "$DATA_MNT" "$ROOT_MNT/data"
  mount --bind "$DATA_MNT/home" "$ROOT_MNT/home"

  ok "merged root mounted at: $ROOT_MNT"
  echo
  echo "  base version : $(cat "$ROOT_MNT/etc/os-release" | awk -F= '/VERSION_ID/{print $2}')"
  echo "  base config  : $(grep hostname "$ROOT_MNT/etc/flipper/base.conf")"
  echo "  profile drop-in present: $(ls "$ROOT_MNT/etc/flipper/conf.d/")"
  echo "  /data marker : $(cat "$ROOT_MNT/data/persistent.marker")"
}

cmd_shell() {
  cmd_boot "$1"
  [ -x "$ROOT_MNT/usr/bin/sh" ] || die "no shell in base (rebuild with busybox installed on host)"
  step "chroot into '$1' — type 'exit' to leave"
  chroot "$ROOT_MNT" /usr/bin/sh || true
}

# -------------------------------------------------------------- status ------
cmd_status() {
  step "Mounts"; mount | grep -E "$LAB_ROOT" || echo "  (none)"
  step "Loop devices"; losetup -a | grep -E "$LAB_ROOT" || echo "  (none)"
  step "dm-verity"; veritysetup status "$DM_BASE" 2>/dev/null || echo "  (closed)"
  if is_mounted "$POOL_MNT"; then step "Btrfs subvolumes"; btrfs subvolume list "$POOL_MNT" 2>/dev/null || true; fi
}

# ------------------------------------------------------------ teardown ------
cmd_teardown() {
  need_root teardown
  step "Tearing down"
  unmount_root
  close_base
  is_mounted "$POOL_MNT" && umount "$POOL_MNT" || true
  is_mounted "$DATA_MNT" && umount "$DATA_MNT" || true
  losetup -D 2>/dev/null || true
  ok "unmounted. Disk images kept under $LAB_ROOT (delete the dir to wipe)."
}

# ---------------------------------------------------------------- demo ------
cmd_demo() {
  need_root demo
  cmd_deps
  cmd_build
  cmd_init
  profile_create router
  profile_create network-multitool

  step "1) Boot 'router' and write a RUNTIME change into the overlay"
  cmd_boot router
  echo "runtime_tweak = yes" > "$ROOT_MNT/etc/flipper/conf.d/99-runtime.conf"
  echo "secret-key-material" > "$ROOT_MNT/data/home/wg.key"   # goes to persistent /data
  ok "wrote 99-runtime.conf (overlay) and ~/wg.key (/data)"
  echo "  -> landed in overlay upper? $(ls "$POOL_MNT/router/etc/flipper/conf.d/" | tr '\n' ' ')"
  echo "  -> base squashfs untouched (still read-only, immutable)"

  step "2) Clone 'router' -> 'router-test' (instant, copy-on-write)"
  profile_reset router >/dev/null 2>&1 || true   # ensure overlay released cleanly
  cmd_boot router >/dev/null
  echo "runtime_tweak = yes" > "$ROOT_MNT/etc/flipper/conf.d/99-runtime.conf"
  unmount_root
  profile_clone router router-test

  step "3) BREAK 'router' (simulate a bad experiment)"
  cmd_boot router >/dev/null
  rm -f "$ROOT_MNT/etc/flipper/conf.d/10-router.conf"
  echo "corrupted!!!" > "$ROOT_MNT/etc/flipper/base.conf.broken"
  warn "router profile messed up"
  unmount_root

  step "4) RESET 'router' to pristine — one command, no re-flash"
  profile_reset router
  cmd_boot router >/dev/null
  echo "  -> 99-runtime.conf gone?  $([ -f "$ROOT_MNT/etc/flipper/conf.d/99-runtime.conf" ] && echo NO || echo YES, restored)"
  echo "  -> 10-router.conf back?   $([ -f "$ROOT_MNT/etc/flipper/conf.d/10-router.conf" ] && echo YES || echo NO)"

  step "5) /data SURVIVED the reset (the whole point of the separate partition)"
  echo "  -> wg.key still present? $([ -f "$ROOT_MNT/data/home/wg.key" ] && echo YES || echo NO)"
  unmount_root

  step "6) Profiles now on the device"
  profile_list

  if [ "$NOVERITY" != "1" ]; then
    step "7) dm-verity integrity: tamper detection"
    cp "$BASE_IMG" "$LAB_ROOT/tampered.img"
    # flip bytes *inside* the hashed data area (midpoint), so verity actually sees it
    local _sz _off; _sz="$(stat -c%s "$LAB_ROOT/tampered.img")"; _off=$(( _sz / 2 ))
    dd if=/dev/urandom of="$LAB_ROOT/tampered.img" bs=1 count=32 seek="$_off" conv=notrunc status=none
    if veritysetup verify "$LAB_ROOT/tampered.img" "$VERITY_HASH" "$(cat "$VERITY_ROOTHASH")" >/dev/null 2>&1; then
      warn "tamper NOT detected (unexpected)"
    else
      ok "tampered base REJECTED by dm-verity (integrity guaranteed)"
    fi
    rm -f "$LAB_ROOT/tampered.img"
  fi

  cmd_teardown
  echo
  ok "demo complete — that's Phase-0 of the RFC working on your machine."
  echo "   Next: wire the 'boot' logic into a real initramfs hook (see initramfs/flipper-overlay.sh)"
  echo "   then move to QEMU aarch64 to add U-Boot A/B + RAUC rollback."
}

# -------------------------------------------------------------- dispatch ----
cmd="${1:-}"; shift || true
case "$cmd" in
  deps)     cmd_deps ;;
  build)    cmd_build ;;
  init)     cmd_init ;;
  profile)
    sub="${1:-}"; shift || true
    case "$sub" in
      list)   profile_list ;;
      create) profile_create "${1:-}" ;;
      clone)  profile_clone "${1:-}" "${2:-}" ;;
      reset)  profile_reset "${1:-}" ;;
      *) die "usage: profile {list|create <id>|clone <id> <new>|reset <id>}" ;;
    esac ;;
  boot)     cmd_boot "${1:-}" ;;
  shell)    cmd_shell "${1:-}" ;;
  status)   cmd_status ;;
  demo)     cmd_demo ;;
  teardown) cmd_teardown ;;
  ""|-h|--help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' (try: ./lab.sh --help)" ;;
esac

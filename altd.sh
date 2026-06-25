#!/usr/bin/env bash
#
# altd.sh — local PoC for RFC "Alternative D": an ALL-BTRFS base + fs-verity
#
# Sibling of lab.sh. Where lab.sh implements the proposed Option A
# (squashfs + dm-verity base), this script implements Alternative D — the
# direction the Flipper team (alchark) is exploring in PR #361:
#
#   - immutable base : Btrfs SUBVOLUME, sealed read-only, integrity via fs-verity
#                      (per-file authenticity) instead of whole-device dm-verity
#   - multiple bases : coexist in ONE Btrfs pool, sharing extents via CoW
#                      (a new base = snapshot + delta => costs only the delta)
#   - profiles       : Btrfs subvolumes (overlay upperdirs), clone/reset via snapshots
#   - /data          : separate persistent partition, bind-mounted
#   - "boot <base> <id>" : assembles the OverlayFS exactly like the initramfs would
#
# This is the hybrid we offered alchark: keep native Btrfs CoW/branching AND an
# integrity story. No RK3576 board required; runs on any Linux host with root.
#
# Usage:  sudo ./altd.sh <command>
#   deps                       check required tools + kernel fs-verity
#   init                       create the Btrfs pool (bases+profiles) + /data
#   base build <version>       create + populate + fs-verity-seal a base subvolume
#   base derive <src> <new>    snapshot a base, change the delta, re-seal (cheap)
#   base list                  list bases + PROVE multi-base dedup (du / qgroups)
#   base verify <version>      immutability + measurement + tamper checks
#   profile list|create <id>|clone <id> <new>|reset <id>
#   boot <version> <id>        assemble + mount the overlay (base >= profile's min)
#   lint <id>                  fail if the profile shadows a base file (anti-drift MUST)
#   shell <version> <id>       boot then chroot (needs busybox in base)
#   status                     show mounts / loops / subvolumes / qgroups
#   teardown                   unmount everything, detach loops
#   demo                       narrated end-to-end walkthrough
#
# Env toggles:
#   LAB_ROOT=<dir>   where runtime artifacts live (default: ./run-altd)
#   NOFSV=1          skip fs-verity (plain read-only Btrfs base) — use if your
#                    kernel lacks CONFIG_FS_VERITY (Btrfs fs-verity needs >= 5.15)
#
set -euo pipefail

# ---------------------------------------------------------------- config ----
LAB_ROOT="${LAB_ROOT:-$PWD/run-altd}"
NOFSV="${NOFSV:-0}"

POOL_IMG="$LAB_ROOT/altd.btrfs"      # single Btrfs pool: bases/ + profiles/
DATA_IMG="$LAB_ROOT/data.ext4"       # separate persistent /data

MNT="$LAB_ROOT/mnt"
POOL_MNT="$MNT/pool"                 # the all-Btrfs stack
DATA_MNT="$MNT/data"                 # persistent /data
ROOT_MNT="$MNT/root"                 # merged overlay = the "booted" system

BASE_VERSION="1.4.0"                 # default base_min_version for new profiles

# --------------------------------------------------------------- helpers ----
c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_rst=$'\033[0m'
log()  { echo "${c_blue}::${c_rst} $*"; }
ok()   { echo "${c_grn}ok${c_rst} $*"; }
warn() { echo "${c_yel}!!${c_rst} $*" >&2; }
die()  { echo "${c_red}xx${c_rst} $*" >&2; exit 1; }
step() { echo; echo "${c_blue}========== $* ==========${c_rst}"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo ./altd.sh $*)"; }
is_mounted() { mountpoint -q "$1"; }

# $1 >= $2 ?  (real version compare — improves on lab.sh's exact-match guard)
ver_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# fs-verity capability probe: can we actually enable verity on this pool?
fsv_probe() {
  local t="$POOL_MNT/.fsv-probe"
  echo x > "$t" 2>/dev/null || return 1
  if fsverity enable "$t" >/dev/null 2>&1; then rm -f "$t" 2>/dev/null || true; return 0; fi
  rm -f "$t" 2>/dev/null || true; return 1
}

# ----------------------------------------------------------------- deps -----
cmd_deps() {
  step "Checking dependencies"
  local missing=0
  declare -A pkg=(
    [mkfs.btrfs]=btrfs-progs [btrfs]=btrfs-progs [fsverity]=fsverity
    [mkfs.ext4]=e2fsprogs    [losetup]=util-linux [mountpoint]=util-linux
  )
  for bin in mkfs.btrfs btrfs fsverity mkfs.ext4 losetup mountpoint; do
    if command -v "$bin" >/dev/null 2>&1; then ok "$bin"; else warn "MISSING $bin (apt pkg: ${pkg[$bin]})"; missing=1; fi
  done
  echo
  if [ "$missing" -eq 1 ]; then
    echo "Install on Debian/Ubuntu:"
    echo "  sudo apt-get update && sudo apt-get install -y fsverity btrfs-progs e2fsprogs util-linux"
    die "missing dependencies"
  fi
  # kernel fs-verity (built-in, not a module): check the running kernel config
  if [ "$NOFSV" = "1" ]; then
    warn "NOFSV=1 — fs-verity disabled by request (Btrfs-only demo)"
  elif grep -qs 'CONFIG_FS_VERITY=y' "/boot/config-$(uname -r)" 2>/dev/null; then
    ok "kernel: CONFIG_FS_VERITY=y"
  else
    warn "could not confirm CONFIG_FS_VERITY=y for $(uname -r)"
    warn "  -> if fs-verity is unavailable, run with NOFSV=1 (Btrfs dedup demo still works)"
  fi
  ok "dependencies satisfied"
}

# --------------------------------------------------------------- init -------
cmd_init() {
  need_root init
  step "Initialising the all-Btrfs stack (one pool: bases/ + profiles/) + /data"
  mkdir -p "$POOL_MNT" "$DATA_MNT" "$ROOT_MNT"

  [ -f "$POOL_IMG" ] || { truncate -s 4G "$POOL_IMG"; mkfs.btrfs -q -f "$POOL_IMG"; }
  [ -f "$DATA_IMG" ] || { truncate -s 512M "$DATA_IMG"; mkfs.ext4 -q -F "$DATA_IMG"; }

  is_mounted "$POOL_MNT" || mount -o loop "$POOL_IMG" "$POOL_MNT"
  is_mounted "$DATA_MNT" || mount -o loop "$DATA_IMG" "$DATA_MNT"

  mkdir -p "$POOL_MNT/bases" "$POOL_MNT/profiles" "$POOL_MNT/.work" "$POOL_MNT/.pristine" "$POOL_MNT/.manifests"
  # qgroups give the authoritative "what does each base cost ALONE" number (excl).
  btrfs quota enable "$POOL_MNT" >/dev/null 2>&1 || warn "btrfs quotas unavailable (dedup shown via 'du' only)"

  # Seed /data: this is what MUST survive both profile reset AND base swap.
  mkdir -p "$DATA_MNT/home" "$DATA_MNT/captures"
  [ -f "$DATA_MNT/persistent.marker" ] || echo "created $(date -Is)" > "$DATA_MNT/persistent.marker"

  if [ "$NOFSV" != "1" ]; then
    fsv_probe && ok "fs-verity works on this pool" || \
      die "fs-verity unavailable on this kernel (need CONFIG_FS_VERITY + Btrfs >= 5.15) — re-run with NOFSV=1"
  fi
  ok "pool mounted at $POOL_MNT (Btrfs: bases/ + profiles/)"
  ok "/data mounted at $DATA_MNT (persistent)"
}

# ------------------------------------------------------- base build/seal ----
write_os_release() {
  local d="$1" v="$2"
  cat > "$d/etc/os-release" <<EOF
NAME="Flipper OS (lab, Alternative D)"
ID=flipper-os
VERSION_ID=$v
PRETTY_NAME="Flipper OS lab base $v (all-Btrfs + fs-verity)"
EOF
}

build_rootfs() {
  local d="$1" v="$2"
  mkdir -p "$d"/{usr/bin,usr/lib,etc/flipper/conf.d,etc/systemd/network,home,data,var}
  write_os_release "$d" "$v"
  echo "$v" > "$d/usr/lib/flipper-base.version"
  cat > "$d/etc/flipper/base.conf" <<EOF
# base.conf — shipped by the immutable base, fs-verity-sealed, read-only.
hostname = flipper-lab
log_level = info
EOF
  echo "I am the immutable base. You cannot write here." > "$d/etc/flipper/README"
  # A few MB of incompressible payload so the multi-base dedup accounting is
  # visually obvious: a derived base shares this whole extent for ~0 cost.
  head -c 24000000 /dev/urandom > "$d/usr/lib/base-payload.bin"
  if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$d/usr/bin/busybox"
    ln -sf busybox "$d/usr/bin/sh"; ln -sf busybox "$d/usr/bin/ls"; ln -sf busybox "$d/usr/bin/cat"
    mkdir -p "$d/bin"; ln -sf ../usr/bin/sh "$d/bin/sh"
  fi
}

# Seal a base: enable fs-verity on every regular file (irreversible, content-
# immutable), record each measured digest in a manifest, then mark the subvol
# read-only. fs-verity is per-FILE, so symlinks/dirs are skipped automatically
# by `find -type f`. Order matters: enable verity WHILE writable, then set ro.
seal_base() {
  local v="$1"; local sub="$POOL_MNT/bases/$v"
  local manifest="$POOL_MNT/.manifests/$v"; : > "$manifest"
  if [ "$NOFSV" = "1" ]; then
    warn "NOFSV=1 — base '$v' left as plain read-only Btrfs (no fs-verity seal)"
  else
    local n=0
    while IFS= read -r -d '' f; do
      # idempotent: skip files that already carry verity (measure succeeds)
      fsverity measure "$f" >/dev/null 2>&1 || fsverity enable "$f"
      printf '%s  %s\n' "$(fsverity measure "$f" | awk '{print $1}')" "${f#"$sub/"}" >> "$manifest"
      n=$((n + 1))
    done < <(find "$sub" -type f -print0)
    ok "fs-verity enabled + measured on $n base files (manifest: .manifests/$v)"
  fi
  btrfs property set "$sub" ro true
  ok "base '$v' sealed read-only"
}

base_build() {
  need_root base
  local v="$1"; [ -n "$v" ] || die "usage: base build <version>"
  is_mounted "$POOL_MNT" || die "run 'init' first"
  [ -d "$POOL_MNT/bases/$v" ] && die "base '$v' already exists"
  step "Building immutable base '$v' (Btrfs subvolume + fs-verity)"
  btrfs subvolume create "$POOL_MNT/bases/$v" >/dev/null
  build_rootfs "$POOL_MNT/bases/$v" "$v"
  seal_base "$v"
}

# Derive a NEW base from an existing one. The snapshot shares every extent with
# the source (O(metadata)); we then replace only the small delta (version files
# + a new base-owned tool) and re-seal. This is the multi-base coexistence +
# dedup that a squashfs base structurally cannot do.
base_derive() {
  need_root base
  local src="$1" dst="$2"; [ -n "$src" ] && [ -n "$dst" ] || die "usage: base derive <src-version> <new-version>"
  is_mounted "$POOL_MNT" || die "run 'init' first"
  [ -d "$POOL_MNT/bases/$src" ] || die "no such base '$src'"
  [ -d "$POOL_MNT/bases/$dst" ] && die "base '$dst' already exists"
  step "Deriving base '$dst' from '$src' (snapshot + delta)"
  btrfs subvolume snapshot "$POOL_MNT/bases/$src" "$POOL_MNT/bases/$dst" >/dev/null
  # sealed files are content-immutable; replacing one = unlink (allowed) + rewrite
  rm -f "$POOL_MNT/bases/$dst/usr/lib/flipper-base.version" "$POOL_MNT/bases/$dst/etc/os-release"
  echo "$dst" > "$POOL_MNT/bases/$dst/usr/lib/flipper-base.version"
  write_os_release "$POOL_MNT/bases/$dst" "$dst"
  echo "tool shipped in base $dst" > "$POOL_MNT/bases/$dst/usr/bin/tool-$dst"
  seal_base "$dst"
  ok "derived '$src' -> '$dst' (unchanged files stay shared via CoW)"
}

base_list() {
  is_mounted "$POOL_MNT" || die "run 'init' first"
  step "Bases (immutable, fs-verity-sealed)"
  local any=0 d
  for d in "$POOL_MNT"/bases/*/; do [ -d "$d" ] || continue; echo "  - $(basename "$d")"; any=1; done
  [ "$any" = 1 ] || { echo "  (none)"; return; }
  echo
  log "per-base extent accounting — Exclusive is what each base costs ALONE:"
  btrfs filesystem du -s "$POOL_MNT"/bases/*/ 2>/dev/null || warn "btrfs filesystem du unavailable"
  echo
  log "qgroup rfer-vs-excl — a derived base 'references' the full size but 'exclusively owns' ~the delta:"
  btrfs quota rescan -w "$POOL_MNT" >/dev/null 2>&1 || true
  btrfs qgroup show -re "$POOL_MNT" 2>/dev/null || warn "qgroups unavailable (run as root, quotas enabled at init)"
}

base_verify() {
  need_root base
  local v="$1"; [ -n "$v" ] || die "usage: base verify <version>"
  local sub="$POOL_MNT/bases/$v"; [ -d "$sub" ] || die "no such base '$v'"
  step "Integrity: base '$v'"

  local probe="$sub/etc/flipper/base.conf"
  if [ "$NOFSV" = "1" ]; then warn "NOFSV=1 — fs-verity checks skipped"; return; fi

  # 1) REAL kernel enforcement: a sealed base file rejects in-place writes.
  if [ -f "$probe" ]; then
    if ( echo tamper >> "$probe" ) 2>/dev/null; then
      warn "write to sealed base file SUCCEEDED (unexpected — verity not enforcing?)"
    else
      ok "in-place write to base.conf DENIED by the kernel (read-only subvolume + fs-verity)"
    fi
  fi

  # 2) measurement re-check: every file still matches its sealed digest.
  local manifest="$POOL_MNT/.manifests/$v"
  if [ -f "$manifest" ]; then
    local bad=0 digest rel cur
    while read -r digest rel; do
      [ -n "$rel" ] || continue
      cur="$(fsverity measure "$sub/$rel" 2>/dev/null | awk '{print $1}')"
      [ "$cur" = "$digest" ] || { warn "DIGEST MISMATCH: $rel"; bad=$((bad + 1)); }
    done < "$manifest"
    [ "$bad" -eq 0 ] && ok "all $(wc -l < "$manifest") files match their sealed fs-verity digests"
  fi

  # 3) tamper detection (offline analog, mirrors lab.sh's dm-verity copy-test):
  #    a single flipped byte changes the fs-verity digest, so any divergence
  #    from the sealed manifest is detected. (cp does NOT carry verity, so the
  #    copy is a plain mutable file we can flip.)
  if [ -f "$probe" ]; then
    local tmp="$LAB_ROOT/tampered.conf" before after
    cp "$probe" "$tmp"
    before="$(fsverity digest --compact "$tmp")"
    printf 'X' | dd of="$tmp" bs=1 seek=0 count=1 conv=notrunc status=none
    after="$(fsverity digest --compact "$tmp")"
    if [ "$before" != "$after" ]; then
      ok "tamper detected: 1 flipped byte changed the digest"
      echo "     before: $before"
      echo "     after : $after"
    else
      warn "tamper NOT reflected in digest (unexpected)"
    fi
    rm -f "$tmp"
  fi
}

# ------------------------------------------------------------- profile ------
profile_exists() { btrfs subvolume show "$POOL_MNT/profiles/$1" >/dev/null 2>&1; }

profile_create() {
  need_root profile
  local id="$1"; [ -n "$id" ] || die "usage: profile create <id> [base_min_version]"
  local minv="${2:-$BASE_VERSION}"
  is_mounted "$POOL_MNT" || die "run 'init' first"
  profile_exists "$id" && die "profile '$id' already exists"
  btrfs subvolume create "$POOL_MNT/profiles/$id" >/dev/null
  mkdir -p "$POOL_MNT/profiles/$id/etc/flipper/conf.d" "$POOL_MNT/profiles/$id/etc/systemd/network"
  cat > "$POOL_MNT/profiles/$id/etc/flipper/conf.d/10-$id.conf" <<EOF
# drop-in added by profile '$id' (overlay upper, writable)
profile = $id
EOF
  cat > "$POOL_MNT/profiles/$id/profile.toml" <<EOF
[profile]
id = "$id"
base_min_version = "$minv"
EOF
  mkdir -p "$POOL_MNT/.work/$id"
  btrfs subvolume snapshot -r "$POOL_MNT/profiles/$id" "$POOL_MNT/.pristine/$id" >/dev/null
  ok "profile '$id' created (base_min_version=$minv, + pristine snapshot)"
}

profile_clone() {
  need_root profile
  local src="$1" dst="$2"; [ -n "$src" ] && [ -n "$dst" ] || die "usage: profile clone <id> <new>"
  profile_exists "$src" || die "no such profile '$src'"
  profile_exists "$dst" && die "'$dst' already exists"
  btrfs subvolume snapshot "$POOL_MNT/profiles/$src" "$POOL_MNT/profiles/$dst" >/dev/null
  btrfs subvolume snapshot -r "$POOL_MNT/profiles/$dst" "$POOL_MNT/.pristine/$dst" >/dev/null
  mkdir -p "$POOL_MNT/.work/$dst"
  ok "cloned '$src' -> '$dst' (copy-on-write, O(metadata))"
}

profile_reset() {
  need_root profile
  local id="$1"; [ -n "$id" ] || die "usage: profile reset <id>"
  [ -d "$POOL_MNT/.pristine/$id" ] || die "no pristine snapshot for '$id'"
  is_mounted "$ROOT_MNT" && unmount_root
  btrfs subvolume delete "$POOL_MNT/profiles/$id" >/dev/null
  btrfs subvolume snapshot "$POOL_MNT/.pristine/$id" "$POOL_MNT/profiles/$id" >/dev/null
  rm -rf "$POOL_MNT/.work/$id"; mkdir -p "$POOL_MNT/.work/$id"
  ok "profile '$id' reset to pristine"
}

profile_list() {
  is_mounted "$POOL_MNT" || die "run 'init' first"
  step "Profiles"
  local any=0 d
  for d in "$POOL_MNT"/profiles/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}profile.toml" ] && { echo "  - $(basename "$d")"; any=1; }
  done
  [ "$any" = 1 ] || echo "  (none)"
}

# ---------------------------------------------------------------- boot ------
unmount_root() {
  if is_mounted "$ROOT_MNT"; then
    for sub in home data captures; do
      is_mounted "$ROOT_MNT/$sub" && umount "$ROOT_MNT/$sub" || true
    done
    umount "$ROOT_MNT" || true
  fi
}

cmd_boot() {
  need_root boot
  local base="$1" id="$2"
  [ -n "$base" ] && [ -n "$id" ] || die "usage: boot <base-version> <profile-id>"
  is_mounted "$POOL_MNT" || die "run 'init' first"
  [ -d "$POOL_MNT/bases/$base" ] || die "no such base '$base' (build it first)"
  profile_exists "$id" || die "no such profile '$id' (create it first)"

  # base_min_version guard — a real ">=" check (RFC anti-corruption guard).
  local need; need="$(awk -F'\"' '/base_min_version/{print $2}' "$POOL_MNT/profiles/$id/profile.toml" 2>/dev/null || true)"
  if [ -n "$need" ] && ! ver_ge "$base" "$need"; then
    die "profile '$id' needs base >= $need but you asked for base $base (refusing to mount)"
  fi

  step "Booting profile '$id' on base '$base'  (initramfs equiv: flipper.profile=$id flipper.base=$base)"
  unmount_root
  mkdir -p "$POOL_MNT/.work/$id"
  # THE core step: assemble the OverlayFS. Identical to lab.sh — overlayfs does
  # not care that the read-only lower is a Btrfs subvolume instead of a squashfs.
  mount -t overlay overlay \
    -o "lowerdir=$POOL_MNT/bases/$base,upperdir=$POOL_MNT/profiles/$id,workdir=$POOL_MNT/.work/$id" \
    "$ROOT_MNT"
  # Bind persistent /data into known paths so it survives reset + base swaps.
  mkdir -p "$ROOT_MNT/data"
  mount --bind "$DATA_MNT" "$ROOT_MNT/data"
  mount --bind "$DATA_MNT/home" "$ROOT_MNT/home"

  ok "merged root mounted at: $ROOT_MNT"
  echo "  base version : $(cat "$ROOT_MNT/usr/lib/flipper-base.version" 2>/dev/null)"
  echo "  base config  : $(grep hostname "$ROOT_MNT/etc/flipper/base.conf" 2>/dev/null)"
  echo "  profile drop-in present: $(ls "$ROOT_MNT/etc/flipper/conf.d/" 2>/dev/null | tr '\n' ' ')"
  echo "  /data marker : $(cat "$ROOT_MNT/data/persistent.marker" 2>/dev/null)"
}

cmd_shell() {
  cmd_boot "$1" "$2"
  [ -x "$ROOT_MNT/usr/bin/sh" ] || die "no shell in base (rebuild with busybox installed on host)"
  step "chroot into '$2' on base '$1' — type 'exit' to leave"
  chroot "$ROOT_MNT" /usr/bin/sh || true
}

# ---------------------------------------------------------------- lint ------
# RFC anti-drift MUST (filesystem-independent — carried over from lab.sh): a
# profile MUST NOT shadow a base file; it may only write drop-ins under *.d/.
is_whitelisted() {
  case "$1" in
    profile.toml)                  return 0 ;;
    */conf.d/*)                    return 0 ;;
    */*.d/*)                       return 0 ;;
    etc/systemd/network/*.network) return 0 ;;
    */udev/rules.d/*)              return 0 ;;
  esac
  return 1
}

cmd_lint() {
  need_root lint
  local id="$1"; [ -n "$id" ] || die "usage: lint <profile-id>"
  is_mounted "$POOL_MNT" || die "run 'init' first"
  profile_exists "$id" || die "no such profile '$id'"
  step "Shadow lint: profile '$id' vs immutable base files (RFC anti-drift MUST)"
  local violations=0
  while IFS= read -r -d '' f; do
    local rel="${f#"$POOL_MNT/profiles/$id/"}"
    # a violation = the profile ships a path that ANY base also ships (and it is
    # not a whitelisted drop-in). Dirs overlapping is normal for OverlayFS.
    local shadows=0 b
    for b in "$POOL_MNT"/bases/*/; do [ -f "$b$rel" ] && { shadows=1; break; }; done
    if [ "$shadows" = 1 ]; then
      if is_whitelisted "$rel"; then ok "drop-in (allowed): $rel"
      else warn "SHADOW: '$rel' overrides a base file"; violations=$((violations + 1)); fi
    fi
  done < <(find "$POOL_MNT/profiles/$id" -type f -print0)
  echo
  if [ "$violations" -gt 0 ]; then
    die "lint FAILED: profile '$id' shadows $violations base file(s) — use a *.d/ drop-in instead"
  fi
  ok "lint passed: '$id' writes only drop-ins, shadows no base file"
}

# -------------------------------------------------------------- status ------
cmd_status() {
  step "Mounts"; mount | grep -E "$LAB_ROOT" || echo "  (none)"
  step "Loop devices"; losetup -a | grep -E "$LAB_ROOT" || echo "  (none)"
  if is_mounted "$POOL_MNT"; then
    step "Btrfs subvolumes"; btrfs subvolume list "$POOL_MNT" 2>/dev/null || true
    step "Btrfs qgroups (rfer/excl)"; btrfs qgroup show -re "$POOL_MNT" 2>/dev/null || echo "  (quotas off)"
  fi
}

# ------------------------------------------------------------ teardown ------
cmd_teardown() {
  need_root teardown
  step "Tearing down"
  unmount_root
  is_mounted "$POOL_MNT" && umount "$POOL_MNT" || true
  is_mounted "$DATA_MNT" && umount "$DATA_MNT" || true
  # detach only OUR loop devices — a global `losetup -D` would hit unrelated
  # loops on a shared CI runner.
  for d in $(losetup -j "$POOL_IMG" -O NAME -n 2>/dev/null) $(losetup -j "$DATA_IMG" -O NAME -n 2>/dev/null); do
    losetup -d "$d" 2>/dev/null || true
  done
  ok "unmounted. Disk images kept under $LAB_ROOT (delete the dir to wipe)."
}

# ---------------------------------------------------------------- demo ------
cmd_demo() {
  need_root demo
  cmd_deps
  cmd_init

  step "1) Build base 1.4.0 (Btrfs subvolume, fs-verity-sealed)"
  base_build 1.4.0

  step "2) Derive base 1.5.0 from 1.4.0 — multiple bases coexisting in ONE pool"
  base_derive 1.4.0 1.5.0
  base_list
  echo "  -> note 1.5.0's tiny Exclusive/excl: a second base costs ~the delta, not a full copy."
  echo "  -> this is exactly what a single squashfs base CANNOT do (alchark's point in PR #361)."

  step "3) Create profile 'router' and boot it on base 1.4.0"
  profile_create router
  cmd_boot 1.4.0 router
  echo "runtime_tweak = yes" > "$ROOT_MNT/etc/flipper/conf.d/99-runtime.conf"
  echo "secret-key-material" > "$ROOT_MNT/data/home/wg.key"   # -> persistent /data
  ok "wrote 99-runtime.conf (overlay upper) and ~/wg.key (/data)"
  echo "  -> landed in overlay upper? $(ls "$POOL_MNT/profiles/router/etc/flipper/conf.d/" | tr '\n' ' ')"
  unmount_root

  step "4) Clone 'router' -> 'router-test' (instant, copy-on-write)"
  profile_clone router router-test

  step "5) BREAK 'router', then RESET to pristine — one command, no re-flash"
  cmd_boot 1.4.0 router >/dev/null
  rm -f "$ROOT_MNT/etc/flipper/conf.d/10-router.conf"
  echo "corrupted!!!" > "$ROOT_MNT/etc/flipper/base.conf.broken"
  unmount_root
  profile_reset router
  cmd_boot 1.4.0 router >/dev/null
  echo "  -> 99-runtime.conf gone?   $([ -f "$ROOT_MNT/etc/flipper/conf.d/99-runtime.conf" ] && echo NO || echo "YES, restored")"
  echo "  -> 10-router.conf back?    $([ -f "$ROOT_MNT/etc/flipper/conf.d/10-router.conf" ] && echo YES || echo NO)"

  step "6) BASE SWAP: re-boot the SAME profile on base 1.5.0 (>= its min 1.4.0)"
  unmount_root
  cmd_boot 1.5.0 router >/dev/null
  echo "  -> base version now: $(cat "$ROOT_MNT/usr/lib/flipper-base.version")"
  echo "  -> wg.key in /data still present? $([ -f "$ROOT_MNT/data/home/wg.key" ] && echo YES || echo NO)  (survived the base swap)"
  unmount_root

  step "7) base_min_version guard: a profile needing base >= 2.0.0 must REFUSE on 1.5.0"
  profile_create locked 2.0.0 >/dev/null
  # cmd_boot calls die()->exit on refusal; contain it in a subshell so the demo
  # continues and the `if` can observe the non-zero status.
  if ( cmd_boot 1.5.0 locked ) >/dev/null 2>&1; then
    warn "guard did NOT refuse (unexpected)"
  else
    ok "guard REFUSED 'locked' (needs >= 2.0.0) on base 1.5.0 — anti-corruption check works"
  fi

  step "8) Anti-drift shadow lint (RFC MUST: profiles never shadow base files)"
  cmd_lint router
  echo "  -> now plant an illegal shadow (overwrite a base file in the upper)..."
  echo "i am illegally shadowing the base" > "$POOL_MNT/profiles/router/etc/flipper/base.conf"
  if ( cmd_lint router ) >/dev/null 2>&1; then
    warn "lint did NOT catch the shadow (unexpected)"
  else
    ok "lint REJECTED the planted shadow of etc/flipper/base.conf (drift blocked)"
  fi
  rm -f "$POOL_MNT/profiles/router/etc/flipper/base.conf"

  if [ "$NOFSV" != "1" ]; then
    step "9) fs-verity integrity: immutability + tamper detection"
    base_verify 1.4.0
  fi

  cmd_teardown
  echo
  ok "demo complete — that's RFC Alternative D (all-Btrfs base + fs-verity) on your machine."
  echo "   Headline: multiple bases coexist for ~the delta (CoW dedup) AND keep an integrity"
  echo "   story (fs-verity) — the hybrid offered to the Flipper team in PR #361."
}

# -------------------------------------------------------------- dispatch ----
cmd="${1:-}"; shift || true
case "$cmd" in
  deps)     cmd_deps ;;
  init)     cmd_init ;;
  base)
    sub="${1:-}"; shift || true
    case "$sub" in
      build)  base_build  "${1:-}" ;;
      derive) base_derive "${1:-}" "${2:-}" ;;
      list)   base_list ;;
      verify) base_verify "${1:-}" ;;
      *) die "usage: base {build <version>|derive <src> <new>|list|verify <version>}" ;;
    esac ;;
  profile)
    sub="${1:-}"; shift || true
    case "$sub" in
      list)   profile_list ;;
      create) profile_create "${1:-}" "${2:-}" ;;
      clone)  profile_clone "${1:-}" "${2:-}" ;;
      reset)  profile_reset "${1:-}" ;;
      *) die "usage: profile {list|create <id> [min]|clone <id> <new>|reset <id>}" ;;
    esac ;;
  boot)     cmd_boot "${1:-}" "${2:-}" ;;
  lint)     cmd_lint "${1:-}" ;;
  shell)    cmd_shell "${1:-}" "${2:-}" ;;
  status)   cmd_status ;;
  teardown) cmd_teardown ;;
  demo)     cmd_demo ;;
  ""|-h|--help)
    sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' (try: ./altd.sh --help)" ;;
esac

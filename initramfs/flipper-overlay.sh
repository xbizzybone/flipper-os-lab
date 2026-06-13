#!/bin/sh
#
# flipper-overlay.sh — REFERENCE initramfs hook (not run by the lab directly)
#
# Shows how `lab.sh boot <id>` maps onto a real initramfs `local-bottom`/init
# script on the device. The only difference vs the lab is *where the profile id
# comes from*:
#
#   - LAB         : passed on the lab.sh command line
#   - SBC (Phase 1): kernel cmdline  ->  flipper.profile=<id> flipper.slot=<A|B>
#   - Flipper One : the MCU renders the boot menu and hands the selection to
#                   U-Boot over the Interconnect (BOOT_SELECTION I2C message),
#                   which sets exactly that cmdline. See the RFC.
#
# Place under /etc/initramfs-tools/scripts/local-bottom/ (dracut: a similar
# module) and regenerate the initramfs.

set -e

# 1) Parse the selection the bootloader handed us.
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        flipper.profile=*) PROFILE="${arg#flipper.profile=}" ;;
        flipper.slot=*)    SLOT="${arg#flipper.slot=}" ;;
        flipper.action=*)  ACTION="${arg#flipper.action=}" ;;   # boot|clone|reset
    esac
done
: "${PROFILE:=minimal}" "${SLOT:=A}" "${ACTION:=boot}"

BASE_DEV="/dev/mapper/base_${SLOT}"     # opened by an earlier verity step
POOL="/run/profiles"                    # Btrfs profiles pool, already mounted
DATA="/run/data"                        # persistent partition, already mounted
ROOT="/root"                            # where the merged system gets switch_root'd

# 2) Optional pre-boot action requested from the menu.
case "$ACTION" in
    reset) btrfs subvolume delete "$POOL/$PROFILE"
           btrfs subvolume snapshot "$POOL/.pristine/$PROFILE" "$POOL/$PROFILE" ;;
    clone) btrfs subvolume snapshot "$POOL/$PROFILE" "$POOL/${PROFILE}-$(date +%s)" ;;
esac

# 3) base_min_version guard: refuse to mount an incompatible profile.
BASE_VER="$(awk -F= '/VERSION_ID/{print $2}' "$BASE_DEV.os-release" 2>/dev/null || echo unknown)"
NEED="$(awk -F'\"' '/base_min_version/{print $2}' "$POOL/$PROFILE/profile.toml" 2>/dev/null || echo "")"
if [ -n "$NEED" ] && [ "$NEED" != "$BASE_VER" ]; then
    echo "profile $PROFILE needs base $NEED, have $BASE_VER — refusing"; exit 1
fi

# 4) THE assembly: read-only verity base + writable profile upper + work dir.
mkdir -p "$POOL/.work/$PROFILE"
mount -t overlay overlay \
    -o "lowerdir=$BASE_DEV,upperdir=$POOL/$PROFILE,workdir=$POOL/.work/$PROFILE" \
    "$ROOT"

# 5) Bind persistent state so it survives profile reset AND A/B base swaps.
mount --bind "$DATA/home" "$ROOT/home"
mount --bind "$DATA"      "$ROOT/data"

# 6) Hand control to the real system.
exec switch_root "$ROOT" /sbin/init

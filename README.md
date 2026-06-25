# flipper-os-lab — local PoC for the Flipper OS storage RFC

[![Phase-0 PoC](https://github.com/xbizzybone/flipper-os-lab/actions/workflows/demo.yml/badge.svg)](https://github.com/xbizzybone/flipper-os-lab/actions/workflows/demo.yml)

> Reference implementation for [flipperone-docs#361](https://github.com/flipperdevices/flipperone-docs/pull/361) — CI runs the full 8-step demo (incl. real dm-verity tamper detection + anti-drift lint) on every push.

A self-contained lab that reproduces **Phase-0 of the Flipper OS storage architecture
RFC** on your own machine — no RK3576 board, no QEMU. It builds the real storage stack
on loop-backed disk images, so every mechanism (dm-verity, Btrfs, OverlayFS) is the
genuine kernel feature, just on files instead of eMMC.

## What it demonstrates

| RFC claim | How the lab proves it |
|---|---|
| Immutable, integrity-checked base | `base.squashfs` mounted read-only via **dm-verity**; tamper test rejects a flipped byte |
| Profiles = cheap, writable overlays | each profile is a **Btrfs subvolume** used as the OverlayFS `upperdir` |
| Instant clone | `profile clone` = `btrfs subvolume snapshot` (copy-on-write, O(metadata)) |
| Reset to pristine, no re-flash | `profile reset` restores from a read-only pristine snapshot |
| `/data` survives reset **and** base swap | separate partition, bind-mounted; survives every reset |
| No `/etc` drift | profiles only write drop-ins under `conf.d/`, never shadow a base file |
| Drift is mechanically blocked | `lint` fails the profile if its upper shadows any base file (RFC anti-drift **MUST**) — the demo plants an illegal shadow and watches it get rejected |
| `base_min_version` guard | `boot` refuses a profile whose required base version doesn't match |
| Boot = assemble overlay from a selection | `boot <id>` does exactly what the initramfs hook does for `flipper.profile=<id>` |

## Prerequisites

- **Linux with root** (native, or a Linux VM). 
- Tools: `squashfs-tools cryptsetup btrfs-progs e2fsprogs util-linux`
  ```
  sudo apt-get install -y squashfs-tools cryptsetup btrfs-progs e2fsprogs util-linux
  ```
- Kernel modules: `overlay`, `squashfs`, `btrfs`, `dm_verity`.

> **WSL2 note:** the default WSL2 kernel often lacks `dm_verity` and/or `btrfs`.
> If so, run everything with `NOVERITY=1` (plain read-only squashfs lower) or use a
> proper Linux VM for full fidelity. `./lab.sh deps` tells you what's missing.

## Quick start

```bash
chmod +x lab.sh
sudo ./lab.sh deps        # check tools + kernel modules
sudo ./lab.sh demo        # full narrated end-to-end walkthrough
```

`demo` builds the base, creates two profiles, boots one, writes runtime changes,
clones it, breaks it, resets it, proves `/data` survived, runs the anti-drift
shadow lint (and watches it reject a planted shadow), and verifies dm-verity
tamper detection — then tears everything down.

### Driving it by hand

```bash
sudo ./lab.sh build                      # squashfs + dm-verity base
sudo ./lab.sh init                       # Btrfs profiles pool + /data
sudo ./lab.sh profile create router
sudo ./lab.sh profile create network-multitool
sudo ./lab.sh boot router                # assemble + mount the overlay
sudo ./lab.sh lint router                # fail if the profile shadows a base file
sudo ./lab.sh shell router               # (if busybox present) chroot in
sudo ./lab.sh profile clone router router-test
sudo ./lab.sh profile reset router       # back to pristine
sudo ./lab.sh status
sudo ./lab.sh teardown
```

Runtime artifacts live in `./run/` (override with `LAB_ROOT=/path`). Delete that
directory to wipe everything.

## How it maps to real hardware

`lab.sh boot <id>` is the desktop stand-in for the early-boot script in
[`initramfs/flipper-overlay.sh`](initramfs/flipper-overlay.sh). The only thing that
changes on real hardware is **where the profile id comes from**:

- **Lab:** the command line you type.
- **SBC (Phase 1):** kernel cmdline `flipper.profile=<id> flipper.slot=<A|B>`.
- **Flipper One:** the MCU renders the boot menu and hands the selection to U-Boot
  over the Interconnect (`BOOT_SELECTION` I²C message), which sets that cmdline.

## Alternative D — the all-Btrfs base (what the Flipper team is exploring)

[`lab.sh`](lab.sh) implements the RFC's **proposed** Option A: a `squashfs + dm-verity`
base. In [PR #361](https://github.com/flipperdevices/flipperone-docs/pull/361) the
Flipper team (`alchark`) is exploring a different base — **everything on Btrfs**, so
multiple bases coexist space-efficiently and clone/branch instantly via CoW. That's
incompatible with whole-device dm-verity (verity needs a static block image), so the
open question is integrity.

[`altd.sh`](altd.sh) is a second, self-contained PoC of that direction — the **hybrid**
we proposed back: an **all-Btrfs base sealed with `fs-verity`** (per-file integrity)
instead of squashfs + dm-verity. It keeps native Btrfs CoW/branching **and** an
integrity story. Same overlay/profile/`/data` model, one Btrfs pool.

| Alternative-D claim | How `altd.sh` proves it |
|---|---|
| Base = immutable, integrity-checked | Btrfs subvolume, every file sealed with **`fs-verity`**; sealed files reject in-place writes (kernel `EPERM`) |
| Multiple bases coexist cheaply | `base derive` = `btrfs subvolume snapshot` + delta; `base list` shows the new base's **Exclusive/excl ≈ the delta**, not a full copy (`btrfs filesystem du` + qgroups) |
| Integrity without dm-verity | `base verify` re-measures every file vs its sealed digest, and shows a 1-byte change flips the `fs-verity` digest |
| Same profile model | profiles are Btrfs subvolumes used as the OverlayFS `upperdir`; clone/reset via snapshots |
| `/data` survives reset **and** base swap | separate partition, bind-mounted; demo boots one profile on base `1.4.0`, then on `1.5.0`, `/data` intact |
| Real `>=` version guard | `boot <base> <profile>` refuses a base older than the profile's `base_min_version` (a proper version compare, improving on `lab.sh`'s exact-match) |
| No `/etc` drift | the same anti-drift `lint` carries over unchanged |

```bash
sudo ./altd.sh demo            # full all-Btrfs + fs-verity walkthrough
sudo ./altd.sh base list       # see the multi-base dedup accounting
NOFSV=1 sudo ./altd.sh demo    # Btrfs-only fallback if the kernel lacks fs-verity
```

> **Requires** `fsverity btrfs-progs e2fsprogs util-linux` and a kernel with
> `CONFIG_FS_VERITY=y` (Btrfs fs-verity needs ≥ 5.15). CI runs the full demo on
> `ubuntu-24.04` on every push ([altd.yml](.github/workflows/altd.yml)).

## Roadmap from here

1. **(this lab)** storage model: verity base + Btrfs overlay profiles + `/data`. ✅
2. **initramfs hook** — drop `flipper-overlay.sh` into `local-bottom/`, regenerate
   the initramfs, boot it in a VM.
3. **QEMU aarch64** — add U-Boot A/B slot selection + RAUC bootcount rollback
   (`qemu-system-aarch64 -M virt`).
4. **Free ARM64 box / CI** — run the build + a boot/overlay smoke test on an Oracle
   Always-Free Ampere instance or GitHub `ubuntu-24.04-arm` runners.
5. **Real board** — flash the ArmSoM Sige5 and bring up the board-specific path.

Attach a recording or the `demo` log to the RFC PR (#361) — a working Phase-0
prototype is exactly what turns a proposal into something the team can build on.

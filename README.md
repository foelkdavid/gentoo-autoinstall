# gentoo-autoinstall
Interactive Gentoo-on-ZFS installer modeled after `../voidzfs-install`.

## What it does
- `amd64` only
- `UEFI` only
- root on `ZFS`
- optional native ZFS encryption
- optional mirrored pool with dual ESPs
- boots with `ZFSBootMenu`
- uses `OpenRC`, not `runit`
- installs:
  - a selectable kernel set, not just one kernel
  - `gentoo-kernel-bin`
  - `gentoo-kernel`
  - optionally one manual kernel built from the live config or a custom `.config`

## What it assumes
- You are running from a Gentoo live environment with working ZFS tools and module support.
- You are okay with the installer wiping the selected disk(s).
- You want an OpenRC-based system with `dhcpcd`, ZFS import/mount services, the `zfs-autosnap` snapshot service, and optional EFI sync.

## Usage
Boot a Gentoo live ISO that has ZFS available, log in as root, and:

```sh
git clone https://github.com/foelkdavid/gentoo-autoinstall
cd gentoo-autoinstall
./install.sh
```

The installer prompts for disk(s), mirror mode, swap size, hostname, sudo user, timezone, keymap, encryption, and kernel set. After the configuration summary you get one last `c/r/e` prompt before any disk is touched.

## Repo layout
- `install.sh`: main interactive installer
- `configs/make.conf`: base Portage template copied into the target system
- `services/efisync`: long-running EFI mirror sync script plus OpenRC service
- `services/zfs-autosnap`: snapshot dispatcher daemon, OpenRC service, and default job config

## Snapshots
Snapshots are managed by the `zfs-autosnap` OpenRC service (no cron). It runs as a supervised background daemon that wakes every `INTERVAL` seconds and fires any jobs whose schedule slot has been reached.

Files on the installed system:
- `/usr/local/bin/zfs-autosnap.sh` — daemon script
- `/etc/init.d/zfs-autosnap` — OpenRC service (enabled in `default` runlevel)
- `/etc/conf.d/zfs-autosnap` — `INTERVAL`, `JOBS`, `STATE` overrides (default `INTERVAL=300`, i.e. 5 min)
- `/etc/zfs-autosnap/jobs.conf` — job definitions
- `/var/lib/zfs-autosnap/` — per-job last-run timestamps
- `/var/log/zfs-autosnap.log` — service log

`jobs.conf` format (pipe-separated):
```
name|dataset|label|schedule|keep|slack|flags
```
Schedule tokens: `-H0 -M0` (daily 00:00), `-H* -M0` (hourly), `-H* -M/15` (every 15 min). `slack` (e.g. `1h`, `1d`) bounds how late a missed slot may still fire. `flags=r` makes the snapshot recursive.

Defaults ship with daily-root (recursive), hourly-home, and daily-home. Edit `jobs.conf` and `rc-service zfs-autosnap restart` to apply changes.

Manual control:
```sh
rc-service zfs-autosnap status
rc-service zfs-autosnap restart
tail -f /var/log/zfs-autosnap.log
```

## Notes
- The installer fetches a prebuilt `ZFSBootMenu` EFI image from `https://get.zfsbootmenu.org/efi`.
- The ZFSBootMenu install path follows the current documented prebuilt-EFI flow: write `VMLINUZ.EFI` and `VMLINUZ-BACKUP.EFI` to the ESP and create direct EFI boot entries with `efibootmgr`. A `BOOTX64.EFI` fallback is also written for firmware that ignores NVRAM entries.
- The root filesystem is mounted by ZFS, so `/etc/fstab` only contains ESP and swap entries.

## Local checks
```sh
make check
```

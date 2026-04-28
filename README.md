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
- You want an OpenRC-based system with `dhcpcd`, `cronie`, ZFS import/mount services, and optional EFI sync.

## Repo layout
- `install.sh`: main interactive installer
- `configs/make.conf`: base Portage template copied into the target system
- `services/efisync`: long-running EFI mirror sync script plus OpenRC service
- `services/zfs-autosnap`: cron-driven snapshot dispatcher and default job config

## Notes
- The installer fetches a prebuilt `ZFSBootMenu` EFI image from `https://get.zfsbootmenu.org/efi`.
- The ZFSBootMenu install path follows the current documented prebuilt-EFI flow: write `VMLINUZ.EFI` and `VMLINUZ-BACKUP.EFI` to the ESP and create direct EFI boot entries with `efibootmgr`.
- Snapshot scheduling is cron-based in v1, not a supervised background worker.
- The root filesystem is mounted by ZFS, so `/etc/fstab` only contains ESP and swap entries.

## Local checks
```sh
make check
```

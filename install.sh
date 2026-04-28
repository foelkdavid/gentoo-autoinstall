#!/usr/bin/env bash

set -Eeo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_MNT=/mnt
TARGET_ROOT_DATASET="zroot/ROOT/gentoo"

GENTOO_STAGE3_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
GENTOO_STAGE3_LATEST="latest-stage3-amd64-openrc.txt"
GENTOO_PROFILE="default/linux/amd64/23.0"
GENTOO_ZBM_URL="https://get.zfsbootmenu.org/efi"
GENTOO_ZBM_IMAGE_DIR="/boot/efi/EFI/ZBM"
GENTOO_ZBM_PRIMARY="VMLINUZ.EFI"
GENTOO_ZBM_BACKUP="VMLINUZ-BACKUP.EFI"

GENTOO_CHECK_HOSTNAME=false

R=$'\033[0;31m'
G=$'\033[0;32m'
Y=$'\033[0;33m'
P=$'\033[0;35m'
LB=$'\033[1;34m'
NC=$'\033[0m'

FAILED=0
CLEANUP_ACTIVE=0
POOL_IMPORTED=0
INSTALL_SUCCESS=0

ok() { printf "  %b %s\n" "${G}✔${NC}" "$1"; }
fail() { printf "  %b %s\n" "${R}✘${NC}" "$1"; }
failhard() { printf "  %b\n" "${R}✘ $1${NC}"; }
info() { printf "%b%s%b\n" "$P" "$1" "$NC"; }
note() { printf "  %b%s%b\n" "$LB" "$1" "$NC"; }

die() {
	failhard "$1"
	exit 1
}

cleanup() {
	local rc=$?

	if [[ $INSTALL_SUCCESS -eq 1 ]]; then
		return 0
	fi

	if [[ $CLEANUP_ACTIVE -eq 1 ]]; then
		umount -n -R "$TARGET_MNT" >/dev/null 2>&1 || true
	fi

	if [[ $POOL_IMPORTED -eq 1 ]]; then
		zfs unmount -a >/dev/null 2>&1 || true
		zpool export zroot >/dev/null 2>&1 || true
	fi

	exit "$rc"
}

trap cleanup EXIT

check() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$desc"
	else
		fail "$desc"
		FAILED=1
	fi
}

print_header() {
	clear
	echo "────────────────────────────"
	echo -e "${G}Gentoo ZFS Installer${NC}"
	echo "────────────────────────────"
}

print_preconf_header() {
	print_header
	echo -e "${Y}[Configuration]${NC}"
	echo -e "  Disk1        -> [ ${Y}${GENTOO_DISK1:-}${NC} ] ${GENTOO_DISK1_SIZE:-}"
	echo -e "  Mirror       -> [ ${Y}${GENTOO_MIRROR:-false}${NC} ]"
	echo -e "  Disk2        -> [ ${Y}${GENTOO_DISK2:-}${NC} ] ${GENTOO_DISK2_SIZE:-}"
	echo -e "  Swap(GB)     -> [ ${Y}${GENTOO_SWAPSIZE:-}${NC} ] ${GENTOO_MIRROR:+(per disk)}"
	echo -e "  Hostname     -> [ ${Y}${GENTOO_HOSTNAME:-}${NC} ]"
	echo -e "  Sudo User    -> [ ${Y}${GENTOO_SUDOUSER:-}${NC} ]"
	echo -e "  Timezone     -> [ ${Y}${GENTOO_TIMEZONE:-}${NC} ]"
	echo -e "  Keymap       -> [ ${Y}${GENTOO_KEYMAP:-}${NC} ]"
	echo -e "  Encryption   -> [ ${Y}${GENTOO_ENCRYPT:-false}${NC} ]"
	echo -e "  Kernel Set   -> [ ${Y}${GENTOO_KERNEL_LABEL:-}${NC} ]"
	echo "────────────────────────────"
}

print_postconf_header() {
	print_header
	echo -e "${Y}[Installing]${NC}"
}

hostnamecheck() {
	if [[ $GENTOO_CHECK_HOSTNAME != true ]]; then
		return 0
	fi

	local hn
	hn="$(hostname || true)"
	if [[ $hn == gentoo || $hn == minimal ]]; then
		return 0
	fi

	failhard "Hostname '$hn' not allowed for destructive install."
	return 1
}

zfscheck() {
	command -v zpool >/dev/null 2>&1 || return 1
	command -v zfs >/dev/null 2>&1 || return 1
	command -v zgenhostid >/dev/null 2>&1 || return 1
	modprobe -n zfs >/dev/null 2>&1 || return 1
	return 0
}

servicecheck() {
	local files=(
		"configs/make.conf"
		"services/efisync/efisync.sh"
		"services/efisync/openrc/efisync"
		"services/efisync/openrc/conf.d.efisync"
		"services/zfs-autosnap/jobs.conf"
		"services/zfs-autosnap/zfs-autosnap.sh"
		"services/zfs-autosnap/openrc/zfs-autosnap"
		"services/zfs-autosnap/openrc/conf.d.zfs-autosnap"
	)
	local f
	for f in "${files[@]}"; do
		[[ -e "$SCRIPT_DIR/$f" ]] || {
			failhard "Missing required file: $f"
			return 1
		}
	done
	return 0
}

run_prechecks() {
	print_header
	info "[Running pre-checks]"
	FAILED=0

	check "Running as root" test "$(id -u)" -eq 0
	check "Bash is available" command -v bash
	check "Running on amd64/x86_64" test "$(uname -m)" = x86_64
	check "System booted in EFI mode" test -d /sys/firmware/efi
	check "Required installer assets exist" servicecheck
	check "Required ZFS userspace and module available" zfscheck
	check "Check hostname guard" hostnamecheck
	check "Connectivity to 1.1.1.1 (ICMP)" ping -c2 -W2 1.1.1.1
	check "DNS resolution (gentoo.org)" ping -c2 -W2 gentoo.org

	local bins=(
		awk blkid chroot curl dd find grep gzip lsblk mkswap mkfs.vfat
		modprobe mount partprobe sgdisk sha256sum sha512sum sed tar umount
		wipefs zfs zpool
	)
	local bin
	for bin in "${bins[@]}"; do
		check "Binary available: $bin" command -v "$bin"
	done

	if [[ $FAILED -ne 0 ]]; then
		echo
		die "Some pre-checks failed."
	fi
}

validate_hostname() {
	local h="$1"
	[[ $h =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

validate_username() {
	local u="$1"
	[[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
	[[ $u != root ]] || return 1
	return 0
}

validate_timezone() {
	local tz="$1"
	[[ $tz =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || return 1

	# Prefer a live zoneinfo check when it exists, but do not make the live
	# environment a hard requirement for a valid timezone string.
	if [[ -e /usr/share/zoneinfo/$tz ]]; then
		return 0
	fi

	return 0
}

validate_keymap() {
	loadkeys -q "$1" >/dev/null 2>&1 && return 0
	find /usr/share/kbd/keymaps -type f \( -name "$1.map.gz" -o -name "$1.map" \) | grep -q .
}

resolve_live_kernel_config() {
	if [[ -r /proc/config.gz ]]; then
		printf "%s\n" "/proc/config.gz"
		return 0
	fi

	local boot_cfg
	boot_cfg="/boot/config-$(uname -r)"
	if [[ -r $boot_cfg ]]; then
		printf "%s\n" "$boot_cfg"
		return 0
	fi

	return 1
}

join_by() {
	local sep="$1"
	shift || return 0
	local out=""
	local item
	for item in "$@"; do
		if [[ -z $out ]]; then
			out="$item"
		else
			out+="${sep}${item}"
		fi
	done
	printf '%s\n' "$out"
}

append_kernel_plan() {
	local entry="$1"
	local label="$2"

	local existing
	for existing in "${GENTOO_KERNEL_PLAN[@]}"; do
		[[ $existing == "$entry" ]] && return 0
	done

	GENTOO_KERNEL_PLAN+=("$entry")
	GENTOO_KERNEL_LABELS+=("$label")
}

kernel_plan_has_mode() {
	local wanted="$1"
	local entry type
	for entry in "${GENTOO_KERNEL_PLAN[@]}"; do
		type="${entry%%|*}"
		[[ $type == "$wanted" ]] && return 0
	done
	return 1
}

kernel_plan_has_dist() {
	kernel_plan_has_mode gentoo-kernel-bin || kernel_plan_has_mode gentoo-kernel
}

get_disks() {
	info "[Select disk $([[ -n ${GENTOO_DISK1:-} ]] && echo 2 || echo 1)]"

	local disklist chosen_disk disk_var size_var disk_size
	disklist="$(lsblk -ndo NAME,SIZE,TYPE -dp | awk '$3=="disk"{printf "  %-20s %s\n", $1, $2}')"
	echo -e "${LB}${disklist}${NC}"
	echo "────────────────────────────"

	while true; do
		read -rp "Enter the full path of the disk you want to use: " chosen_disk

		if ! lsblk -dno NAME -p | grep -qx "$chosen_disk"; then
			failhard "Invalid disk path: $chosen_disk"
		elif [[ $chosen_disk == "${GENTOO_DISK1:-}" ]]; then
			failhard "You already selected this disk: $chosen_disk"
		else
			disk_var="GENTOO_DISK1"
			size_var="GENTOO_DISK1_SIZE"
			if [[ -n ${GENTOO_DISK1:-} ]]; then
				disk_var="GENTOO_DISK2"
				size_var="GENTOO_DISK2_SIZE"
			fi

			printf -v "$disk_var" "%s" "$chosen_disk"
			read -r disk_size < <(lsblk -dnpo SIZE "$chosen_disk")
			printf -v "$size_var" "(%s)" "$disk_size"
			break
		fi
	done
}

mirror_decision() {
	while :; do
		read -rp "Do you want to create a mirrored ZFS pool? (y/n) " yn
		case "${yn,,}" in
			y | yes)
				GENTOO_MIRROR=true
				print_preconf_header
				get_disks
				break
				;;
			n | no)
				GENTOO_MIRROR=false
				unset GENTOO_DISK2 GENTOO_DISK2_SIZE
				break
				;;
			*)
				echo "Please answer y or n."
				;;
		esac
	done
}

get_swapsize() {
	info "[Swap configuration]"
	note "Swap will be created on each disk in mirror mode."
	echo "────────────────────────────"
	while true; do
		read -rp "Enter swap size in GB: " GENTOO_SWAPSIZE || true
		if [[ ${GENTOO_SWAPSIZE:-} =~ ^[0-9]+$ ]] && [[ $GENTOO_SWAPSIZE -gt 0 ]]; then
			break
		fi
		failhard "Invalid input. Please enter a positive integer."
	done
}

get_hostname() {
	info "[Set hostname]"
	note "Validity is checked automatically."
	echo "────────────────────────────"
	while true; do
		read -rp "Enter hostname for the new system: " GENTOO_HOSTNAME || true
		if validate_hostname "$GENTOO_HOSTNAME"; then
			break
		fi
		failhard "Invalid hostname: $GENTOO_HOSTNAME"
	done
}

get_sudouser() {
	info "[Configure sudo user]"
	note "This user will be added to the wheel group."
	echo "────────────────────────────"
	while true; do
		read -rp "Enter username for the new system: " GENTOO_SUDOUSER || true
		if validate_username "$GENTOO_SUDOUSER"; then
			break
		fi
		failhard "Invalid username: $GENTOO_SUDOUSER"
	done
}

get_timezone() {
	info "[Configure timezone]"
	note "Example: Europe/Vienna"
	echo "────────────────────────────"
	while true; do
		read -rp "Enter timezone: " GENTOO_TIMEZONE || true
		GENTOO_TIMEZONE="${GENTOO_TIMEZONE//$'\r'/}"
		if validate_timezone "$GENTOO_TIMEZONE"; then
			break
		fi
		failhard "Invalid timezone: $GENTOO_TIMEZONE"
	done
}

get_keymap() {
	info "[Configure keymap]"
	note "Example: de-latin1, us, de"
	echo "────────────────────────────"
	while true; do
		read -rp "Enter keymap: " GENTOO_KEYMAP || true
		if validate_keymap "$GENTOO_KEYMAP"; then
			break
		fi
		failhard "Invalid keymap: $GENTOO_KEYMAP"
	done
}

encryption_decision() {
	while :; do
		read -rp "Do you want native ZFS encryption? (y/n) " yn
		case "${yn,,}" in
			y | yes)
				GENTOO_ENCRYPT=true
				break
				;;
			n | no)
				GENTOO_ENCRYPT=false
				break
				;;
			*)
				echo "Please answer y or n."
				;;
		esac
	done
}

get_kernel_mode() {
	info "[Kernel selection]"
	echo "  [1] gentoo-kernel-bin"
	echo "  [2] gentoo-kernel"
	echo "  [3] import config from live system"
	echo "  [4] use custom .config"
	note "You can choose multiple entries, for example: 1,2 or 1,4"
	note "At most one manual config source may be selected."
	echo "────────────────────────────"

	while true; do
		local kernel_choice raw_choice token trimmed live_cfg custom_cfg
		local -a kernel_tokens=()

		GENTOO_KERNEL_PLAN=()
		GENTOO_KERNEL_LABELS=()
		read -rp "Select one or more kernel modes [1-4, comma-separated]: " raw_choice
		IFS=',' read -r -a kernel_tokens <<< "$raw_choice"

		if [[ ${#kernel_tokens[@]} -eq 0 ]]; then
			failhard "Select at least one kernel entry."
			continue
		fi

		for token in "${kernel_tokens[@]}"; do
			trimmed="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
			case "$trimmed" in
				1)
					append_kernel_plan "gentoo-kernel-bin" "gentoo-kernel-bin"
					;;
				2)
					append_kernel_plan "gentoo-kernel" "gentoo-kernel"
					;;
				3)
					live_cfg="$(resolve_live_kernel_config)" || {
						failhard "No readable live-system kernel config found."
						GENTOO_KERNEL_PLAN=()
						break
					}
					append_kernel_plan "liveconfig|$live_cfg" "live-config manual kernel"
					;;
				4)
					while true; do
						read -rp "Enter absolute path to the custom kernel .config: " custom_cfg
						if [[ $custom_cfg = /* && -r $custom_cfg ]]; then
							append_kernel_plan "customconfig|$custom_cfg" "custom manual kernel"
							break
						fi
						failhard "Path must be absolute and readable."
					done
					;;
				*)
					failhard "Invalid kernel selection: $trimmed"
					GENTOO_KERNEL_PLAN=()
					break
					;;
			esac
		done

		if [[ ${#GENTOO_KERNEL_PLAN[@]} -eq 0 ]]; then
			continue
		fi

		local manual_count=0
		for token in "${GENTOO_KERNEL_PLAN[@]}"; do
			trimmed="${token%%|*}"
			case "$trimmed" in
				liveconfig | customconfig)
					manual_count=$((manual_count + 1))
					;;
			esac
		done
		if [[ $manual_count -gt 1 ]]; then
			failhard "Select at most one manual kernel config source."
			GENTOO_KERNEL_PLAN=()
			GENTOO_KERNEL_LABELS=()
			continue
		fi

		GENTOO_KERNEL_LABEL="$(join_by ', ' "${GENTOO_KERNEL_LABELS[@]}")"
		break
	done
}

confirm_menu() {
	info "[Configuration finished]"
	note "What do you want to do?"
	echo -e "    [${G}c${NC}] Continue with partitioning"
	echo -e "    [${Y}r${NC}] Restart configuration"
	echo -e "    [${R}e${NC}] Exit without changes"
	while true; do
		read -rp "Choose [c/r/e]: " _ans || true
		case "${_ans,,}" in
			c) return 0 ;;
			r) return 10 ;;
			e) return 20 ;;
		esac
	done
}

get_user_password() {
	while true; do
		read -rsp "Enter password for user '$GENTOO_SUDOUSER': " p1
		echo
		read -rsp "Confirm password for user '$GENTOO_SUDOUSER': " p2
		echo
		if [[ -n $p1 && $p1 == "$p2" ]]; then
			GENTOO_USER_PASSWORD="$p1"
			return 0
		fi
		echo "Passwords did not match or were empty - try again."
	done
}

get_zfs_passphrase() {
	while true; do
		read -rsp "Enter ZFS passphrase: " p1
		echo
		read -rsp "Confirm ZFS passphrase: " p2
		echo
		if [[ -n $p1 && $p1 == "$p2" ]]; then
			GENTOO_ZFS_PASSPHRASE="$p1"
			return 0
		fi
		echo "Passphrases did not match or were empty - try again."
	done
}

get_inputs() {
	run_prechecks
	sleep 1
	print_preconf_header
	get_disks
	print_preconf_header
	mirror_decision
	print_preconf_header
	get_swapsize
	print_preconf_header
	get_hostname
	print_preconf_header
	get_sudouser
	print_preconf_header
	get_timezone
	print_preconf_header
	get_keymap
	print_preconf_header
	encryption_decision
	print_preconf_header
	get_kernel_mode
	print_preconf_header
}

devpart() {
	local disk="$1" part="${2:-1}" sep=""
	[[ $disk =~ ^/dev/(nvme|mmcblk|nbd|loop) ]] && sep="p"
	printf "%s%s%s" "$disk" "$sep" "$part"
}

xchroot() {
	chroot "$TARGET_MNT" /usr/bin/env -i \
		HOME=/root \
		TERM="${TERM:-linux}" \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		"$@"
}

require_target_mount() {
	[[ -d $TARGET_MNT ]] || mkdir -p "$TARGET_MNT"
}

set_disk_vars() {
	BOOT_DEVICE_1="$(devpart "$GENTOO_DISK1" 1)"
	SWAP_DEVICE_1="$(devpart "$GENTOO_DISK1" 2)"
	POOL_DEVICE_1="$(devpart "$GENTOO_DISK1" 3)"
	export BOOT_DEVICE_1 SWAP_DEVICE_1 POOL_DEVICE_1

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		BOOT_DEVICE_2="$(devpart "$GENTOO_DISK2" 1)"
		SWAP_DEVICE_2="$(devpart "$GENTOO_DISK2" 2)"
		POOL_DEVICE_2="$(devpart "$GENTOO_DISK2" 3)"
		export BOOT_DEVICE_2 SWAP_DEVICE_2 POOL_DEVICE_2
	fi
}

partition_disks() {
	local disks=("$GENTOO_DISK1")
	[[ ${GENTOO_MIRROR:-false} == true ]] && disks+=("$GENTOO_DISK2")

	local d
	for d in "${disks[@]}"; do
		info "[Partitioning $d]"
		sgdisk --zap-all "$d" >/dev/null || die "Failed to wipe $d"
		wipefs -a "$d" >/dev/null 2>&1 || true

		sgdisk -n1:1MiB:+512MiB -t1:ef00 -c1:EFI "$d" >/dev/null || die "Failed to create EFI partition on $d"
		sgdisk -n2:0:+"${GENTOO_SWAPSIZE}"GiB -t2:8200 -c2:swap "$d" >/dev/null || die "Failed to create swap partition on $d"
		sgdisk -n3:0:-10MiB -t3:bf00 -c3:zfs "$d" >/dev/null || die "Failed to create ZFS partition on $d"
		partprobe "$d" >/dev/null 2>&1 || true
		ok "Partitioned $d"
	done
}

create_zpool() {
	zgenhostid -f >/dev/null

	local pool_args=(
		-o ashift=12
		-o autotrim=on
		-O acltype=posixacl
		-O compression=zstd
		-O dnodesize=auto
		-O mountpoint=none
		-O normalization=formD
		-O relatime=on
		-O xattr=sa
		-R "$TARGET_MNT"
	)

	local pool_devices=(
		"/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_1")"
	)

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		pool_devices+=(
			"/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_2")"
		)
	fi

	local keyfile=""
	if [[ ${GENTOO_ENCRYPT:-false} == true ]]; then
		keyfile="$(mktemp)"
		chmod 600 "$keyfile"
		printf '%s\n' "$GENTOO_ZFS_PASSPHRASE" >"$keyfile"

		pool_args+=(
			-O encryption=aes-256-gcm
			-O keyformat=passphrase
			-O "keylocation=file://$keyfile"
		)
	fi

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		zpool create -f "${pool_args[@]}" zroot mirror "${pool_devices[@]}" >/dev/null || die "Failed to create mirrored zpool"
	else
		zpool create -f "${pool_args[@]}" zroot "${pool_devices[@]}" >/dev/null || die "Failed to create zpool"
	fi
	POOL_IMPORTED=1

	if [[ ${GENTOO_ENCRYPT:-false} == true ]]; then
		zfs set keylocation=prompt zroot
		rm -f "$keyfile"
		unset GENTOO_ZFS_PASSPHRASE
	fi

	ok "Created zroot pool"
}

create_datasets() {
	info "[Creating ZFS datasets]"
	zfs create -o mountpoint=none zroot/ROOT >/dev/null || die "Failed to create zroot/ROOT"
	zfs create -o mountpoint=/ -o canmount=noauto "$TARGET_ROOT_DATASET" >/dev/null || die "Failed to create $TARGET_ROOT_DATASET"
	zfs create -o mountpoint=/home -o canmount=noauto zroot/home >/dev/null || die "Failed to create zroot/home"
	zpool set bootfs="$TARGET_ROOT_DATASET" zroot
	zfs set org.zfsbootmenu:commandline="quiet loglevel=4" zroot/ROOT

	zfs mount "$TARGET_ROOT_DATASET" || die "Failed to mount root dataset"
	zfs mount zroot/home || die "Failed to mount home dataset"
	CLEANUP_ACTIVE=1

	mkdir -p "$TARGET_MNT/etc/zfs"
	cp /etc/hostid "$TARGET_MNT/etc/hostid"
	zpool set cachefile="$TARGET_MNT/etc/zfs/zpool.cache" zroot

	ok "Mounted root datasets under $TARGET_MNT"
}

format_boot_and_swap() {
	info "[Formatting EFI and swap]"

	mkfs.vfat -F32 "$BOOT_DEVICE_1" >/dev/null || die "Failed to format primary EFI partition"
	mkswap "$SWAP_DEVICE_1" >/dev/null || die "Failed to create primary swap"

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		mkfs.vfat -F32 "$BOOT_DEVICE_2" >/dev/null || die "Failed to format secondary EFI partition"
		mkswap "$SWAP_DEVICE_2" >/dev/null || die "Failed to create secondary swap"
	fi

	ok "Formatted EFI and swap devices"
}

detect_digest_file() {
	local url="$1"
	local out="$2"

	if curl -fsSL "${url}.DIGESTS" -o "$out"; then
		return 0
	fi
	if curl -fsSL "${url}.DIGESTS.asc" -o "$out"; then
		return 0
	fi
	return 1
}

verify_stage3() {
	local archive="$1"
	local digest_file="$2"
	local filename hash

	filename="$(basename "$archive")"

	hash="$(awk -v f="$filename" '$NF == f && length($1) == 128 { print $1; exit }' "$digest_file")"
	if [[ -n $hash ]]; then
		printf "%s  %s\n" "$hash" "$archive" | sha512sum -c - >/dev/null || die "SHA512 verification failed for $filename"
		ok "Verified stage3 with SHA512"
		return 0
	fi

	hash="$(awk -v f="$filename" '$NF == f && length($1) == 64 { print $1; exit }' "$digest_file")"
	if [[ -n $hash ]]; then
		printf "%s  %s\n" "$hash" "$archive" | sha256sum -c - >/dev/null || die "SHA256 verification failed for $filename"
		ok "Verified stage3 with SHA256"
		return 0
	fi

	die "Could not find a usable digest for $filename"
}

download_stage3() {
	info "[Downloading latest Gentoo stage3]"

	local latest_rel stage3_file stage3_url archive_path digest_path
	latest_rel="$(curl -fsSL "${GENTOO_STAGE3_BASE}/${GENTOO_STAGE3_LATEST}" | awk '$1 !~ /^#/ { path = $1 } END { print path }')"
	[[ -n $latest_rel ]] || die "Failed to resolve the latest stage3 path"

	stage3_file="$(basename "$latest_rel")"
	stage3_url="${GENTOO_STAGE3_BASE}/${latest_rel}"
	archive_path="/tmp/${stage3_file}"
	digest_path="/tmp/${stage3_file}.DIGESTS"

	curl -fL "$stage3_url" -o "$archive_path" || die "Failed to download stage3 archive"
	detect_digest_file "$stage3_url" "$digest_path" || die "Failed to download stage3 digest file"
	verify_stage3 "$archive_path" "$digest_path"

	tar xpf "$archive_path" --xattrs --xattrs-include='*.*' --numeric-owner --directory "$TARGET_MNT" || die "Failed to extract stage3"
	ok "Extracted stage3 into $TARGET_MNT"
}

write_make_conf() {
	local jobs
	local extra_use=""
	jobs="$(nproc 2>/dev/null || echo 4)"
	if kernel_plan_has_dist; then
		extra_use=" dist-kernel"
	fi
	sed \
		-e "s/__MAKEOPTS__/$jobs/" \
		-e "s/__GLOBAL_USE_EXTRA__/${extra_use}/" \
		-e 's/  */ /g' \
		"$SCRIPT_DIR/configs/make.conf" >"$TARGET_MNT/etc/portage/make.conf"
}

write_portage_config() {
	info "[Writing Portage configuration]"

	mkdir -p \
		"$TARGET_MNT/etc/portage/package.use" \
		"$TARGET_MNT/etc/portage/package.license" \
		"$TARGET_MNT/etc/portage/package.accept_keywords" \
		"$TARGET_MNT/etc/portage/repos.conf" \
		"$TARGET_MNT/etc/portage/binrepos.conf" \
		"$TARGET_MNT/etc/dracut.conf.d"

	write_make_conf
	cp "$TARGET_MNT/usr/share/portage/config/repos.conf" "$TARGET_MNT/etc/portage/repos.conf/gentoo.conf"
	cp --dereference /etc/resolv.conf "$TARGET_MNT/etc/resolv.conf"

	cat >"$TARGET_MNT/etc/portage/package.license/zfs" <<'EOF'
sys-fs/zfs CDDL
sys-fs/zfs-kmod CDDL
sys-kernel/linux-firmware @BINARY-REDISTRIBUTABLE
EOF

	if kernel_plan_has_dist; then
		cat >"$TARGET_MNT/etc/portage/package.use/zfs" <<'EOF'
sys-fs/zfs dist-kernel initramfs rootfs
EOF
	else
		cat >"$TARGET_MNT/etc/portage/package.use/zfs" <<'EOF'
sys-fs/zfs initramfs rootfs
EOF
	fi

	cat >"$TARGET_MNT/etc/portage/package.use/installkernel" <<'EOF'
sys-kernel/installkernel dracut -systemd
EOF

	if kernel_plan_has_mode gentoo-kernel; then
		echo "sys-kernel/gentoo-kernel ~amd64" >"$TARGET_MNT/etc/portage/package.accept_keywords/gentoo-kernel"
	fi

	cat >"$TARGET_MNT/etc/dracut.conf.d/zfs.conf" <<'EOF'
nofsck="yes"
hostonly="yes"
use_fstab="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF

	ok "Configured Portage and dracut"
}

mount_chroot_support() {
	info "[Mounting chroot support filesystems]"
	mount --types proc /proc "$TARGET_MNT/proc"
	mount --rbind /sys "$TARGET_MNT/sys"
	mount --make-rslave "$TARGET_MNT/sys"
	mount --rbind /dev "$TARGET_MNT/dev"
	mount --make-rslave "$TARGET_MNT/dev"
	mount --bind /run "$TARGET_MNT/run"
	mount --make-slave "$TARGET_MNT/run"
	ok "Mounted proc/sys/dev/run into target"
}

write_locales() {
	cat >"$TARGET_MNT/etc/locale.gen" <<'EOF'
en_US ISO-8859-1
en_US.UTF-8 UTF-8
EOF

	cat >"$TARGET_MNT/etc/env.d/02locale" <<'EOF'
LANG="en_US.UTF-8"
EOF
}

write_openrc_config_files() {
	cat >"$TARGET_MNT/etc/conf.d/hostname" <<EOF
hostname="${GENTOO_HOSTNAME}"
EOF

	echo "$GENTOO_HOSTNAME" >"$TARGET_MNT/etc/hostname"

	cat >"$TARGET_MNT/etc/conf.d/keymaps" <<EOF
keymap="${GENTOO_KEYMAP}"
windowkeys="YES"
dumpkeys_charset=""
fix_euro="YES"
EOF
}

write_fstab() {
	local efi1_uuid swap1_uuid

	efi1_uuid="$(blkid -s UUID -o value "$BOOT_DEVICE_1")"
	swap1_uuid="$(blkid -s UUID -o value "$SWAP_DEVICE_1")"

	cat >"$TARGET_MNT/etc/fstab" <<EOF
# Managed by gentoo-autoinstall
UUID=${efi1_uuid} /boot/efi vfat defaults 0 0
UUID=${swap1_uuid} none swap defaults,nofail 0 0
EOF

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		local efi2_uuid swap2_uuid
		efi2_uuid="$(blkid -s UUID -o value "$BOOT_DEVICE_2")"
		swap2_uuid="$(blkid -s UUID -o value "$SWAP_DEVICE_2")"
		cat >>"$TARGET_MNT/etc/fstab" <<EOF
UUID=${efi2_uuid} /boot/efi2 vfat defaults,nofail 0 0
UUID=${swap2_uuid} none swap defaults,nofail 0 0
EOF
	fi
}

mount_esp_partitions() {
	info "[Mounting EFI partitions]"
	write_fstab

	mkdir -p "$TARGET_MNT/boot/efi"
	mount "$BOOT_DEVICE_1" "$TARGET_MNT/boot/efi"

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		mkdir -p "$TARGET_MNT/boot/efi2"
		mount "$BOOT_DEVICE_2" "$TARGET_MNT/boot/efi2"
	fi

	ok "Mounted EFI partitions"
}

sync_portage_tree() {
	info "[Syncing Portage tree]"
	xchroot emerge-webrsync || die "emerge-webrsync failed"
	ok "Portage snapshot updated"
}

set_profile() {
	info "[Selecting profile ${GENTOO_PROFILE}]"
	xchroot eselect profile set "$GENTOO_PROFILE" >/dev/null || die "Failed to set profile ${GENTOO_PROFILE}"
	ok "Profile selected"
}

emerge_common_packages() {
	info "[Installing base packages]"
	xchroot /bin/bash -lc '
		emerge --verbose --getbinpkg \
			app-admin/sudo \
			app-editors/vim \
			net-misc/dhcpcd \
			net-misc/rsync \
			sys-boot/efibootmgr \
			sys-fs/dosfstools \
			sys-fs/inotify-tools \
			sys-kernel/dracut \
			sys-kernel/installkernel \
			sys-kernel/linux-firmware
	' || die "Failed to install base packages"
	ok "Base packages installed"
}

ensure_linux_symlink() {
	xchroot /bin/bash -lc 'cd /usr/src && ln -sfn "$(ls -1d linux-* | sort -V | tail -n1)" linux' || die "Failed to update /usr/src/linux symlink"
}

copy_kernel_config_into_target() {
	local src="$1"
	local dst="$2"

	if [[ $src == /proc/config.gz ]]; then
		gzip -dc "$src" >"$dst"
	else
		cp "$src" "$dst"
	fi
}

install_manual_kernel_sources() {
	info "[Installing manual kernel build dependencies]"
	xchroot /bin/bash -lc 'emerge --verbose --getbinpkg sys-kernel/gentoo-sources' || die "Failed to install gentoo-sources"
	ensure_linux_symlink
}

build_manual_kernel() {
	local src_cfg="$1"
	local localversion="$2"
	local target_cfg="/tmp/kernel${localversion}.config"

	copy_kernel_config_into_target "$src_cfg" "$TARGET_MNT${target_cfg}"

	info "[Building manual kernel ${localversion}]"
	xchroot /bin/bash -lc "
		cd /usr/src/linux
		make mrproper
		cp ${target_cfg} .config
		make olddefconfig
		make LOCALVERSION=${localversion} -j\$(nproc)
		make LOCALVERSION=${localversion} modules_install
		make LOCALVERSION=${localversion} install
	" || die "Manual kernel build failed for ${localversion}"

	ok "Manual kernel ${localversion} built and installed"
}

install_kernel_and_zfs() {
	local -a dist_kernel_pkgs=()
	local -a manual_entries=()
	local entry type cfg

	for entry in "${GENTOO_KERNEL_PLAN[@]}"; do
		type="${entry%%|*}"
		case "$type" in
			gentoo-kernel-bin)
				dist_kernel_pkgs+=("sys-kernel/gentoo-kernel-bin")
				;;
			gentoo-kernel)
				dist_kernel_pkgs+=("sys-kernel/gentoo-kernel")
				;;
			liveconfig | customconfig)
				manual_entries+=("$entry")
				;;
			*)
				die "Unsupported kernel selection entry: $entry"
				;;
		esac
	done

	if [[ ${#dist_kernel_pkgs[@]} -gt 0 ]]; then
		info "[Installing distribution kernels and ZFS]"
		xchroot /bin/bash -lc "emerge --verbose --getbinpkg sys-fs/zfs ${dist_kernel_pkgs[*]}" || die "Failed to install distribution kernels and sys-fs/zfs"
	fi

	if [[ ${#manual_entries[@]} -gt 0 ]]; then
		install_manual_kernel_sources

		if [[ ${#dist_kernel_pkgs[@]} -eq 0 ]]; then
			info "[Installing ZFS userspace before manual kernel build]"
			xchroot /bin/bash -lc 'emerge --verbose --getbinpkg sys-fs/zfs' || die "Failed to install sys-fs/zfs"
		fi

		local idx=1
		for entry in "${manual_entries[@]}"; do
			cfg="${entry#*|}"
			build_manual_kernel "$cfg" "-manual${idx}"
			idx=$((idx + 1))
		done

		info "[Rebuilding ZFS for manual kernel selection]"
		xchroot /bin/bash -lc 'emerge --verbose --oneshot sys-fs/zfs' || die "Failed to rebuild sys-fs/zfs for manual kernel"
	fi

	if [[ ${#dist_kernel_pkgs[@]} -eq 0 && ${#manual_entries[@]} -eq 0 ]]; then
		die "No kernel selections were resolved."
	fi

	ok "Kernel and ZFS installed"
}

generate_initramfs() {
	info "[Refreshing installed kernels and initramfs images]"
	xchroot kernel-install add-all >/dev/null || die "kernel-install add-all failed"
	ok "Refreshed all installed kernel/initramfs pairs"
}

configure_system_basics() {
	info "[Configuring base system]"
	write_locales
	write_openrc_config_files

	xchroot /bin/bash -lc "ln -sf /usr/share/zoneinfo/${GENTOO_TIMEZONE} /etc/localtime" || die "Failed to set timezone"
	xchroot locale-gen >/dev/null || die "locale-gen failed"
	xchroot env-update >/dev/null || die "env-update failed"

	ok "Timezone, locale, hostname and keymap configured"
}

configure_openrc_services() {
	info "[Enabling OpenRC services]"

	xchroot rc-update add zfs-import boot >/dev/null || true
	xchroot rc-update add zfs-mount boot >/dev/null || true
	xchroot rc-update add zfs-share default >/dev/null || true
	xchroot rc-update add zfs-zed default >/dev/null || true
	xchroot rc-update add dhcpcd default >/dev/null || die "Failed to enable dhcpcd"

	ok "OpenRC services enabled"
}

setup_user() {
	info "[Creating user ${GENTOO_SUDOUSER}]"
	xchroot useradd -m -G wheel "$GENTOO_SUDOUSER" >/dev/null || die "Failed to create user $GENTOO_SUDOUSER"
	printf '%s\n%s\n' "$GENTOO_USER_PASSWORD" "$GENTOO_USER_PASSWORD" | xchroot passwd "$GENTOO_SUDOUSER" >/dev/null || die "Failed to set user password"
	unset GENTOO_USER_PASSWORD

	mkdir -p "$TARGET_MNT/etc/sudoers.d"
	echo "%wheel ALL=(ALL:ALL) ALL" >"$TARGET_MNT/etc/sudoers.d/wheel"
	chmod 440 "$TARGET_MNT/etc/sudoers.d/wheel"

	ok "User and sudo access configured"
}

install_zfsbootmenu() {
	info "[Installing ZFSBootMenu]"

	mkdir -p "$TARGET_MNT${GENTOO_ZBM_IMAGE_DIR}"
	curl -fL "$GENTOO_ZBM_URL" -o "$TARGET_MNT${GENTOO_ZBM_IMAGE_DIR}/${GENTOO_ZBM_PRIMARY}" || die "Failed to fetch ZFSBootMenu EFI image"
	cp "$TARGET_MNT${GENTOO_ZBM_IMAGE_DIR}/${GENTOO_ZBM_PRIMARY}" "$TARGET_MNT${GENTOO_ZBM_IMAGE_DIR}/${GENTOO_ZBM_BACKUP}"

	mkdir -p "$TARGET_MNT/boot/efi/EFI/BOOT"
	cp "$TARGET_MNT${GENTOO_ZBM_IMAGE_DIR}/${GENTOO_ZBM_PRIMARY}" "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		rsync -a --delete "$TARGET_MNT/boot/efi/" "$TARGET_MNT/boot/efi2/" || die "Failed to one-time sync mirrored ESP"
	fi

	xchroot mount -t efivarfs efivarfs /sys/firmware/efi/efivars >/dev/null 2>&1 || true
	xchroot efibootmgr -c -d "$GENTOO_DISK1" -p 1 -L "ZFSBootMenu (Primary)" -l '\EFI\ZBM\VMLINUZ.EFI' >/dev/null || die "Failed to create primary EFI boot entry"
	xchroot efibootmgr -c -d "$GENTOO_DISK1" -p 1 -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI' >/dev/null || die "Failed to create backup EFI boot entry"

	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		xchroot efibootmgr -c -d "$GENTOO_DISK2" -p 1 -L "ZFSBootMenu (Mirror)" -l '\EFI\ZBM\VMLINUZ.EFI' >/dev/null || die "Failed to create mirrored EFI boot entry"
	fi

	ok "ZFSBootMenu installed"
}

install_efisync_assets() {
	[[ ${GENTOO_MIRROR:-false} == true ]] || return 0

	info "[Installing efisync OpenRC service]"
	install -Dm755 "$SCRIPT_DIR/services/efisync/efisync.sh" "$TARGET_MNT/usr/local/bin/efisync.sh"
	install -Dm755 "$SCRIPT_DIR/services/efisync/openrc/efisync" "$TARGET_MNT/etc/init.d/efisync"
	install -Dm644 "$SCRIPT_DIR/services/efisync/openrc/conf.d.efisync" "$TARGET_MNT/etc/conf.d/efisync"

	xchroot rc-update add efisync default >/dev/null || die "Failed to enable efisync"
	ok "efisync installed"
}

install_autosnap_assets() {
	info "[Installing ZFS autosnapshot service]"
	install -Dm755 "$SCRIPT_DIR/services/zfs-autosnap/zfs-autosnap.sh" "$TARGET_MNT/usr/local/bin/zfs-autosnap.sh"
	install -Dm644 "$SCRIPT_DIR/services/zfs-autosnap/jobs.conf" "$TARGET_MNT/etc/zfs-autosnap/jobs.conf"
	install -Dm755 "$SCRIPT_DIR/services/zfs-autosnap/openrc/zfs-autosnap" "$TARGET_MNT/etc/init.d/zfs-autosnap"
	install -Dm644 "$SCRIPT_DIR/services/zfs-autosnap/openrc/conf.d.zfs-autosnap" "$TARGET_MNT/etc/conf.d/zfs-autosnap"

	xchroot rc-update add zfs-autosnap default >/dev/null || die "Failed to enable zfs-autosnap"
	ok "Autosnapshot service installed and enabled"
}

finalize_install() {
	info "[Finalizing installation]"
	umount -n -R "$TARGET_MNT" >/dev/null 2>&1 || true
	CLEANUP_ACTIVE=0
	zpool export zroot || die "Failed to export zroot"
	POOL_IMPORTED=0
	INSTALL_SUCCESS=1

	echo
	echo "────────────────────────────"
	echo -e "${G}Install finished.${NC}"
	echo "────────────────────────────"
	note "Boot via ZFSBootMenu on the primary ESP."
	if [[ ${GENTOO_MIRROR:-false} == true ]]; then
		note "Primary and secondary ESPs were synced once and efisync was enabled."
	fi
	note "zfs-autosnap OpenRC service is enabled and will dispatch periodic snapshots."
}

run_install() {
	print_postconf_header
	echo
	get_user_password
	echo
	if [[ ${GENTOO_ENCRYPT:-false} == true ]]; then
		get_zfs_passphrase
	fi

	require_target_mount
	set_disk_vars
	partition_disks
	format_boot_and_swap
	create_zpool
	create_datasets
	download_stage3
	write_portage_config
	mount_chroot_support
	mount_esp_partitions
	sync_portage_tree
	set_profile
	emerge_common_packages
	configure_system_basics
	install_kernel_and_zfs
	generate_initramfs
	configure_openrc_services
	setup_user
	install_zfsbootmenu
	install_efisync_assets
	install_autosnap_assets
	finalize_install
}

main() {
	while true; do
		get_inputs
		if confirm_menu; then
			rc=0
		else
			rc=$?
		fi

		case "$rc" in
			10)
				unset \
					GENTOO_MIRROR GENTOO_DISK1 GENTOO_DISK1_SIZE GENTOO_DISK2 GENTOO_DISK2_SIZE \
					GENTOO_SWAPSIZE GENTOO_HOSTNAME GENTOO_SUDOUSER GENTOO_TIMEZONE GENTOO_KEYMAP \
					GENTOO_ENCRYPT GENTOO_KERNEL_LABEL GENTOO_KERNEL_PLAN GENTOO_KERNEL_LABELS
				continue
				;;
			20)
				exit 0
				;;
			0)
				break
				;;
		esac
	done

	run_install
}

main "$@"

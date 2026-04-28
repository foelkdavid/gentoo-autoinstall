#!/bin/sh

set -eu

JOBS="${JOBS:-/etc/zfs-autosnap/jobs.conf}"
STATE="${STATE:-/var/lib/zfs-autosnap}"
INTERVAL="${INTERVAL:-300}"

mkdir -p "$STATE"

trim() {
	sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

slack_to_seconds() {
	case "$1" in
		*min) printf '%s\n' "$(( ${1%min} * 60 ))" ;;
		*h) printf '%s\n' "$(( ${1%h} * 3600 ))" ;;
		*d) printf '%s\n' "$(( ${1%d} * 86400 ))" ;;
		*) printf '60\n' ;;
	esac
}

slot_start() {
	case "$1" in
		*"-H0"*"-M0"*)
			date -d 'today 00:00' +%s
			;;
		*"-H*"*"-M0"*)
			date -d "$(date +%F) $(date +%H):00:00" +%s
			;;
		*"-H*"*"-M/15"*)
			m=$(date +%M)
			q=$(( m - (m % 15) ))
			date -d "$(date +%F) $(date +%H):$(printf %02d "$q"):00" +%s
			;;
		*"-H*"*"-M*"*)
			date -d "$(date +%F) $(date +%H):$(date +%M):00" +%s
			;;
		*)
			date +%s
			;;
	esac
}

init_timefile() {
	tf="$1"
	[ -e "$tf" ] || touch -d '@0' "$tf"
}

should_run() {
	sched="$1"
	tf="$2"
	slack="$3"

	slot="$(slot_start "$sched")"
	now="$(date +%s)"
	last="$(stat -c %Y "$tf")"
	slack_s="$(slack_to_seconds "$slack")"

	[ "$last" -lt "$slot" ] || return 1
	[ "$now" -ge "$slot" ] || return 1
	[ "$now" -le $(( slot + slack_s )) ] || return 1
	return 0
}

run_job() {
	name="$1"
	dataset="$2"
	label="$3"
	keep="$4"
	flags="$5"
	tf="$6"

	rflag=""
	printf '%s' "$flags" | grep -q 'r' && rflag="-r"

	prefix="${label%%\$\(*}"
	lpatt="$(printf '%s' "$label" | sed -n 's/.*$(\([^)]*\)).*/\1/p')"
	[ -n "$lpatt" ] || lpatt="%Y%m%d-%H%M"
	snap="${dataset}@${prefix}$(date +"$lpatt")"

	echo "[INFO] $name -> creating $snap"
	zfs snapshot $rflag "$snap"
	touch "$tf"

	echo "[INFO] $name -> pruning old snapshots"
	zfs list -H -t snapshot -o name -S creation \
		| grep "^${dataset}@${prefix}" \
		| tail -n +"$(( keep + 1 ))" \
		| xargs -r -n1 zfs destroy
}

dispatch_once() {
	[ -r "$JOBS" ] || {
		echo "[WARN] $JOBS not readable, skipping tick" >&2
		return 0
	}

	grep -v '^[[:space:]]*\(#\|$\)' "$JOBS" | while IFS='|' read -r name dataset label sched keep slack flags; do
		name=$(printf '%s' "$name" | trim)
		dataset=$(printf '%s' "$dataset" | trim)
		label=$(printf '%s' "$label" | trim)
		sched=$(printf '%s' "$sched" | trim)
		keep=$(printf '%s' "$keep" | trim)
		slack=$(printf '%s' "$slack" | trim)
		flags=$(printf '%s' "$flags" | trim)

		[ -n "$name" ] || continue

		tf="$STATE/${name}.timefile"
		init_timefile "$tf"

		if should_run "$sched" "$tf" "$slack"; then
			run_job "$name" "$dataset" "$label" "$keep" "$flags" "$tf" || \
				echo "[WARN] job $name failed" >&2
		fi
	done
}

trap 'echo "[INFO] zfs-autosnap stopping"; exit 0' INT TERM

echo "[INFO] zfs-autosnap starting (interval=${INTERVAL}s, jobs=$JOBS)"
while :; do
	dispatch_once
	sleep "$INTERVAL"
done

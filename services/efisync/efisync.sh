#!/usr/bin/env bash

set -Eeo pipefail

if [[ $EUID -ne 0 ]]; then
	echo "efisync must run as root." >&2
	exit 1
fi

for bin in flock inotifywait rsync; do
	command -v "$bin" >/dev/null 2>&1 || {
		echo "Missing required command: $bin" >&2
		exit 1
	}
done

: "${SRC:=/boot/efi}"
: "${DST:=/boot/efi2}"
: "${LOCK:=/run/efisync.lock}"

do_sync() {
	printf '[%(%F %T)T] syncing EFI trees...\n' -1
	flock "$LOCK" rsync -a --delete -- "$SRC"/ "$DST"/
	printf '[%(%F %T)T] sync complete.\n' -1
}

do_sync

while inotifywait -qq -r -e close_write,create,delete,move,attrib -- "$SRC"; do
	while inotifywait -qq -r -t 1 -e close_write,create,delete,move,attrib -- "$SRC"; do :; done
	do_sync
done

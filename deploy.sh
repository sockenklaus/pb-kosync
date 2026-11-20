#!/bin/sh
# Deploy pb-kosync onto the PocketBook device over SSH.
#
#   ./deploy.sh            deploy: copy files, add boot hook + shutdown-flush
#                          hook (both backed up / idempotent), then START the
#                          daemon now and show its status
#   ./deploy.sh start      same as plain deploy (kept for familiarity)
#   ./deploy.sh undeploy   remove both hooks (shutdown hook restored from its
#                          backup) and delete the installed files
#
# Requires: a working `config` file next to this script (see config.example),
# and passwordless root SSH to the device (BatchMode).

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"

SSH='ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o BatchMode=yes -o ConnectTimeout=10 root@192.168.205.1'
DEST="/mnt/secure/pb-kosync"

# Hook markers. The flush hook is detected by SUBSTRING so it also matches the
# pre-existing on-device hook (whose start line is a comment, not a bare token).
BOOT_START="#pb-kosync-start"
BOOT_END="#pb-kosync-end"
FLUSH_MARK="pb-kosync-flush"
FLUSH_START="#pb-kosync-flush-start"
FLUSH_END="#pb-kosync-flush-end"

remote() { $SSH "$@"; }

check_config() {
  [ -f config ] || { echo "error: no ./config (copy config.example and fill it in)" >&2; exit 2; }
  # shellcheck disable=SC1091
  . ./config
  : "${CWA_URL:?config: CWA_URL required}" "${CWA_USER:?config: CWA_USER required}" "${CWA_PASS:?config: CWA_PASS required}"
}

# ---------------------------------------------------------------------------
# Boot hook: auto-start the daemon on boot. Exec-bit independent (invoked via
# `sh`), self-guarded by the script's pidfile. Appended between markers; idempotent.
# ---------------------------------------------------------------------------
patch_boot() {
  remote sh -s "$DEST" "$BOOT_START" "$BOOT_END" <<'REMOTE'
dest="$1"; mstart="$2"; mend="$3"
rcs=/etc/init.d/rcS
if grep -qF "$mstart" "$rcs" 2>/dev/null; then
  echo "  boot hook already present in $rcs (skipped)"
  exit 0
fi
mount -o remount,rw / 2>/dev/null || { echo "  ERROR: cannot remount / rw" >&2; exit 1; }
{
  echo ""
  echo "$mstart"
  echo "# pb-kosync auto-start (exec-bit independent: via sh; self-guarded by pidfile)"
  echo "[ -f $dest/pbkosync.sh ] && ( sh $dest/pbkosync.sh loop >/dev/null 2>&1 </dev/null & )"
  echo "$mend"
} >> "$rcs" || { echo "  ERROR: append to $rcs failed" >&2; exit 1; }
mount -o remount,ro / 2>/dev/null
echo "  boot hook added to $rcs"
REMOTE
}

# ---------------------------------------------------------------------------
# Shutdown-flush hook: run a final progress sync at the TOP of rc.shutdown,
# before the device disables USB and deep-sleeps (Wi-Fi still up).
# Backs up the original once; idempotent.
# ---------------------------------------------------------------------------
patch_shutdown() {
  remote sh -s "$DEST" "$FLUSH_MARK" "$FLUSH_START" "$FLUSH_END" <<'REMOTE'
dest="$1"; mark="$2"; mstart="$3"; mend="$4"
rc=/etc/init.d/rc.shutdown
bak="$dest/rc.shutdown.bak-flush"
if grep -qF "$mark" "$rc" 2>/dev/null; then
  echo "  shutdown-flush hook already present in $rc (skipped)"
  exit 0
fi
# Preserve a pristine backup exactly once (never overwrite an existing one).
if [ ! -f "$bak" ]; then
  cp -p "$rc" "$bak" || { echo "  ERROR: backup of $rc failed" >&2; exit 1; }
  echo "  backed up original -> $bak"
fi
mount -o remount,rw / 2>/dev/null || { echo "  ERROR: cannot remount / rw" >&2; exit 1; }
# Insert after the serial-console "OUT=" anchor (before USB-disable + sleep loop).
# Fallback: right after the shebang (top of file). Both keep it ahead of the
# USB-disable and deep-sleep, so Wi-Fi is still up.
tmp="$dest/.rcshutdown.new"
awk -v s="$mstart" -v e="$mend" -v d="$dest" '
  {
    print
    if (done) next
    if ($0 ~ /^OUT=\/dev\/ttyS0/ || (NR==1 && $0 ~ /^#!/)) {
      print s
      print "[ -f " d "/pbkosync.sh ] && sh " d "/pbkosync.sh flush >/dev/null 2>&1"
      print e
      done=1
    }
  }
' "$rc" > "$tmp" || { echo "  ERROR: transform failed" >&2; exit 1; }
# Sanity: the hook must now be present.
n=$(grep -cF "$mark" "$tmp")
case "$n" in ''|0) mount -o remount,ro / 2>/dev/null; echo "  ERROR: hook missing after transform" >&2; exit 1 ;; esac
sh -n "$tmp" 2>/dev/null || echo "  WARNING: transformed $rc failed syntax check (continuing)"
cp "$tmp" "$rc" || { mount -o remount,ro / 2>/dev/null; echo "  ERROR: install $rc failed" >&2; exit 1; }
chmod 0755 "$rc" 2>/dev/null
rm -f "$tmp"
mount -o remount,ro / 2>/dev/null
echo "  shutdown-flush hook added to $rc"
REMOTE
}

# ---------------------------------------------------------------------------
# Undeploy hooks.
# ---------------------------------------------------------------------------
undeploy_boot() {
  remote sh -s "$BOOT_START" "$BOOT_END" <<'REMOTE'
mstart="$1"; mend="$2"
rcs=/etc/init.d/rcS
if ! grep -qF "$mstart" "$rcs" 2>/dev/null; then
  echo "  no boot hook in $rcs (skipped)"
  exit 0
fi
mount -o remount,rw / 2>/dev/null || { echo "  ERROR: cannot remount / rw" >&2; exit 1; }
awk -v s="$mstart" -v e="$mend" '
  $0==s {skip=1; next}
  skip && $0==e {skip=0; next}
  !skip {print}
' "$rcs" > "$rcs.tmp" || { echo "  ERROR: strip failed" >&2; exit 1; }
cat "$rcs.tmp" > "$rcs" && rm -f "$rcs.tmp"
mount -o remount,ro / 2>/dev/null
echo "  boot hook removed from $rcs"
REMOTE
}

undeploy_shutdown() {
  remote sh -s "$DEST" <<'REMOTE'
dest="$1"
rc=/etc/init.d/rc.shutdown
bak="$dest/rc.shutdown.bak-flush"
if [ ! -f "$bak" ]; then
  echo "  no backup of $rc found; leaving $rc as-is"
  exit 0
fi
mount -o remount,rw / 2>/dev/null || { echo "  ERROR: cannot remount / rw" >&2; exit 1; }
cp -p "$bak" "$rc" || { mount -o remount,ro / 2>/dev/null; echo "  ERROR: restore failed" >&2; exit 1; }
chmod 0755 "$rc" 2>/dev/null
mount -o remount,ro / 2>/dev/null
rm -f "$bak"
echo "  restored original $rc from backup (hook removed); backup deleted"
REMOTE
}

# ---------------------------------------------------------------------------
# Start the daemon now: stop any running instance (so fresh code takes effect),
# then launch detached. Self-guarded by the script's pidfile.
# ---------------------------------------------------------------------------
start_daemon() {
  echo "  verifying CWA auth..."
  remote "$DEST/pbkosync.sh check-auth" || echo "  (auth check reported an issue — see above; the daemon will keep retrying)"
  echo "  stopping any running instance..."
  remote "cd $DEST && sh ./pbkosync.sh stop" >/dev/null 2>&1
  echo "  starting daemon..."
  remote "cd $DEST && ( sh ./pbkosync.sh loop >/dev/null 2>&1 </dev/null & )"
  sleep 2
  echo "  --- daemon status ---"
  remote "$DEST/pbkosync.sh status"
}

cmd=${1:-deploy}
case "$cmd" in
  deploy|start)
    check_config
    remote "mkdir -p $DEST"
    # Transfer files over ssh (device has no scp/SFTP).
    for f in pbkosync.sh config; do
      [ -f "$f" ] || continue
      echo "upload $f -> $DEST/$f"
      cat "$f" | remote "cat > $DEST/$f"
    done
    remote "chmod 0755 $DEST/pbkosync.sh; chmod 0600 $DEST/config"
    echo "installing boot hook..."
    patch_boot
    echo "installing shutdown-flush hook..."
    patch_shutdown
    start_daemon
    echo "deploy complete."
    ;;
  undeploy)
    echo "removing shutdown-flush hook..."
    undeploy_shutdown
    echo "removing boot hook..."
    undeploy_boot
    remote "rm -f $DEST/pbkosync.sh $DEST/config $DEST/state $DEST/log $DEST/.pid $DEST/.id $DEST/books.db.bak"
    echo "undeploy complete."
    ;;
  *)
    echo "usage: $0 {deploy|start|undeploy}" >&2
    exit 2
    ;;
esac

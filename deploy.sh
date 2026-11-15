#!/bin/sh
# Deploy pb-kosync onto the PocketBook device over SSH.
#
#   ./deploy.sh            deploy (copy + chmod + patch boot hook + check-auth)
#   ./deploy.sh undeploy   remove boot hook and installed files
#   ./deploy.sh start      deploy, then start the loop daemon now
#
# Requires: a working `config` file next to this script (see config.example),
# and passwordless root SSH to the device (BatchMode).

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"

SSH='ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o BatchMode=yes -o ConnectTimeout=10 root@192.168.205.1'
DEST="/mnt/secure/pb-kosync"
MARK_START="#pb-kosync-start"
MARK_END="#pb-kosync-end"

remote() { $SSH "$@"; }

check_config() {
  [ -f config ] || { echo "error: no ./config (copy config.example and fill it in)" >&2; exit 2; }
  # shellcheck disable=SC1091
  . ./config
  : "${CWA_URL:?config: CWA_URL required}" "${CWA_USER:?config: CWA_USER required}" "${CWA_PASS:?config: CWA_PASS required}"
}

patch_boot() {
  remote sh -s "$DEST" <<'REMOTE'
dest="$1"
rcs=/etc/init.d/rcS
if grep -qF "$MARK_START" "$rcs" 2>/dev/null; then
  echo "boot hook already present in $rcs"
else
  {
    echo ""
    echo "$MARK_START"
    # nohup-style detach; the script self-guards with its pidfile.
    echo "[ -x $dest/pbkosync.sh ] && ( $dest/pbkosync.sh loop >/dev/null 2>&1 & )"
    echo "$MARK_END"
  } >> "$rcs"
  echo "boot hook added to $rcs"
fi
REMOTE
}

undeploy_boot() {
  remote sh -s <<'REMOTE'
rcs=/etc/init.d/rcS
# Strip the pb-kosync block (start..end marker lines inclusive), keep the rest.
awk '
  /^#pb-kosync-start$/ {skip=1; next}
  skip && /^#pb-kosync-end$/ {skip=0; next}
  !skip {print}
' "$rcs" > "$rcs.tmp" && mv "$rcs.tmp" "$rcs"
echo "boot hook removed from $rcs (if present)"
REMOTE
}

cmd=${1:-deploy}
case "$cmd" in
  deploy)
    check_config
    remote "mkdir -p $DEST"
    # Transfer files over ssh (device has no scp).
    remote "cd $DEST" < /dev/null
    for f in pbkosync.sh config; do
      [ -f "$f" ] || continue
      echo "upload $f -> $DEST/$f"
      cat "$f" | remote "cat > $DEST/$f"
    done
    remote "chmod 0755 $DEST/pbkosync.sh; chmod 0600 $DEST/config"
    patch_boot
    echo "deploy complete."
    echo "test auth with:  $SSH '$DEST/pbkosync.sh check-auth'"
    echo "start daemon:    $SSH '$DEST/pbkosync.sh loop &'"
    ;;
  undeploy)
    undeploy_boot
    remote "rm -f $DEST/pbkosync.sh $DEST/config $DEST/state $DEST/log $DEST/.pid $DEST/.id $DEST/books.db.bak"
    echo "undeploy complete."
    ;;
  start)
    "$0" deploy
    remote "cd $DEST && ./pbkosync.sh check-auth"
    remote "cd $DEST && ( ./pbkosync.sh loop >/dev/null 2>&1 & )"
    sleep 2
    remote "$DEST/pbkosync.sh status"
    ;;
  *)
    echo "usage: $0 {deploy|undeploy|start}" >&2
    exit 2
    ;;
esac

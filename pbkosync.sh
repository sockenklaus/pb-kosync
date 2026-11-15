#!/bin/sh
# pb-kosync — sync PocketBook native-reader progress <-> Calibre-Web-Automated (KOSync)
#
# Runs on a PocketBook Era Color (PocketBook OS 6.10). Uses only what the
# device already ships: busybox (dd, md5sum, sed, awk, base64, nc, pgrep,
# date, sleep, mktemp), curl (OpenSSL), sqlite3.
#
# Local progress stores (discovered by forensics on this device):
#   explorer-3.db books_settings  — the native reader's CANONICAL position
#     store: it resumes from here on open and writes back here on close
#     (position, cpage, npage, position_ts). This is the primary source.
#   books.db Tags 80/81/42        — legacy mirror (KOReader writes here
#     too); can be stale. Used as fallback and kept consistent on pull.
#   reader per-book position.cfg  — reader scratch state; kept consistent.
#
# Subcommands:
#   push                 Push local (device) progress to CWA for changed books.
#   pull                 Pull newer server progress back to the device (reader idle only).
#   once                 push, then pull. Handy for manual runs / testing.
#   loop                 Resident daemon: poll, push changes, pull at interval.
#   check-auth           Validate CWA credentials + KOSync endpoint once.
#   status               Show configuration, state and recent log lines.
#   digest <file>        Print the KOReader partial-MD5 digest of a file.
#
# Everything lives in the script's own directory ($AGENT_DIR) so it can be
# deployed to /mnt/secure/pb-kosync/ and survives reboots.

# --- resolve agent dir (directory containing this script) ---
AGENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -n "$AGENT_DIR" ] || AGENT_DIR=.

# --- configuration ---
CFG="$AGENT_DIR/config"
if [ -f "$CFG" ]; then
  . "$CFG"
else
  echo "pb-kosync: missing config file: $CFG" >&2
  echo "  Copy config.example to config and fill in CWA_URL / CWA_USER / CWA_PASS." >&2
  exit 2
fi

: "${CWA_URL:?CWA_URL is required in config}"
: "${CWA_USER:?CWA_USER is required in config}"
: "${CWA_PASS:?CWA_PASS is required in config}"
: "${DEVICE_NAME:=PocketBook Era Color}"
: "${POLL_SEC:=15}"
: "${PULL_SEC:=300}"
: "${PULL_ENABLED:=1}"
: "${PUSH_COOLDOWN:=90}"   # min seconds between pushes of the same book
: "${CURL_MAX:=20}"
: "${DATA_DIR:=/mnt/ext1}"

# Tag IDs in the PocketBook library DB (discovered on this device).
TAG_PROGRESS=80      # doc.read_progress (0..1 float — verified native format)
TAG_POSITION=81      # doc.last_read_position (pbr: URI)
TAG_TIMEOPENED=42    # doc.time_opened (epoch)

# Stable per-installation device id (KOSync `device_id`), generated once.
ID_FILE="$AGENT_DIR/.id"
if [ ! -s "$ID_FILE" ]; then
  printf 'pb-era-color-%s\n' "$(head -c 8 /dev/urandom 2>/dev/null | md5sum | sed 's/ .*//')" > "$ID_FILE" 2>/dev/null
fi
: "${DEVICE_ID:=$(cat "$ID_FILE" 2>/dev/null || echo pb-era-color-0000)}"

BOOKS_DB="$DATA_DIR/system/config/books.db"
EXPLORER_DB="$DATA_DIR/system/explorer-3/explorer-3.db"
READER_STATE_DIR="$DATA_DIR/system/state/cache/reader"
STATE_FILE="$AGENT_DIR/state"
LOG_FILE="$AGENT_DIR/log"
PID_FILE="$AGENT_DIR/.pid"
DB_BACKUP="$AGENT_DIR/books.db.bak"
: "${READER_PROC:=eink-reader}"   # process pattern of the native reader (overridable via config)
: "${PULL_READER_BUSY_SEC:=120}"  # reader considered "busy" if position state changed within this many seconds

mkdir -p "$AGENT_DIR" 2>/dev/null
[ -f "$STATE_FILE" ] || : > "$STATE_FILE"
[ -f "$LOG_FILE" ] || : > "$LOG_FILE"

# --- small helpers -----------------------------------------------------------

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Keep the log bounded.
trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  if [ "$(wc -l < "$LOG_FILE")" -gt 4000 ]; then
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

now() { date +%s; }

# KOReader util.partialMD5, byte-identical (verified against a real KOReader
# digest on this device). Samples 1KiB at offsets 0,1K,4K,16K,64K,256K,1M,4M,
# 16M,64M,256M,1G and MD5s the concatenation; stops at first short read.
partial_md5() {
  [ -r "$1" ] || return 1
  for skip in 0 1 4 16 64 256 1024 4096 16384 65536 262144 1048576; do
    dd if="$1" bs=1024 skip="$skip" count=1 2>/dev/null
  done | md5sum | sed 's/ .*//'
}

# Extract a scalar value from a (flat) JSON document by key.
json_get() { # $1=json $2=key
  printf '%s' "$1" | tr '\n\r\t' '   ' \
    | sed -n 's/.*"'"$2"'":[ ]*\([^,}]*\).*/\1/p' \
    | sed 's/^"//; s/"$//; s/[[:space:]]*$//'
}

extract_cfi() { # $1 = pbr: position -> inner epubcfi(...)
  printf '%s' "$1" | sed -n 's/.*epubcfi(\(.*\)).*/\1/p' | sed 's/[[:space:]]*$//'
}
extract_page() { # $1 = position string -> integer page (first match wins)
  p=$(printf '%s' "$1" | sed -n 's/.*page=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -z "$p" ]; then
    p=$(printf '%s' "$1" | sed -n 's/.*pdfloc([^,]*,\([0-9][0-9]*\)).*/\1/p' | head -n 1)
  fi
  [ -n "$p" ] && printf '%s\n' "$p"
}

# Normalize a reading position (pbr: URI, raw CFI, "page=N", number) to a
# canonical form so equivalent positions compare equal across formats.
norm_loc() { # canonical form for comparing positions across writers
  s=$1
  case "$s" in
    *epubcfi*)
      c=$(extract_cfi "$s"); [ -n "$c" ] && { printf 'cfi:%s' "$c"; return 0; } ;;
  esac
  p=$(extract_page "$s")
  [ -n "$p" ] && { printf 'page:%s' "$p"; return 0; }
  case "$s" in
    ''|*[!0-9]*) : ;;
    *) printf 'page:%s' "$s"; return 0 ;;
  esac
  case "$s" in
    */*) printf 'cfi:%s' "$s"; return 0 ;;   # spine CFI or KOReader content-path CFI
  esac
  printf 'raw:%s' "$s"
}

# CRC32 of a file (lowercase hex), matching the checksum the PocketBook
# reader stores as the last line of its *.cfg state files (verified:
# crc32 of the content above the "#xxxx" line).
crc32_file() {
  hexdump -C "$1" 2>/dev/null | awk '
    function xor32(a, b,   r, p) {
      r = 0; p = 1
      while (a > 0 || b > 0) {
        if ((a % 2) != (b % 2)) r += p
        a = int(a / 2); b = int(b / 2); p *= 2
      }
      return r
    }
    function tohex(n,   s, i) {
      s = ""
      for (i = 0; i < 8; i++) { s = substr("0123456789abcdef", (n % 16) + 1, 1) s; n = int(n / 16) }
      return s
    }
    BEGIN { HEX = "0123456789abcdef"; for (i = 0; i < 16; i++) hv[substr(HEX, i + 1, 1)] = i; c = 4294967295 }
    {
      for (i = 2; i <= 17 && i <= NF; i++) {
        tok = $i
        if (length(tok) != 2) continue
        c1 = substr(tok, 1, 1); c2 = substr(tok, 2, 1)
        if (!(c1 in hv) || !(c2 in hv)) continue
        c = xor32(c, hv[c1] * 16 + hv[c2])
        for (k = 0; k < 8; k++) c = (c % 2 == 1) ? 2147483648 + xor32(int(c / 2), 1840808736) : int(c / 2)
      }
    }
    END { printf "%s", tohex(xor32(c, 4294967295)) }
  '
}

# --- sqlite access -----------------------------------------------------------
# Read-only access via URI (proven to work on this device's sqlite3).
q_ro() { # $1=sql
  sqlite3 "file:$BOOKS_DB?mode=ro" -noheader -separator '|' "$1" 2>/dev/null
}
q_rw() { # $1=sql
  sqlite3 "$BOOKS_DB" -noheader "PRAGMA busy_timeout=5000; $1" 2>&1
}

# explorer-3.db — the native reader's own position store.
ex_ready() { [ -r "$EXPLORER_DB" ]; }
ex_ro() { # $1=sql
  sqlite3 "file:$EXPLORER_DB?mode=ro" -noheader -separator '|' "$1" 2>/dev/null
}
ex_rw() { # $1=sql
  sqlite3 "$EXPLORER_DB" -noheader "PRAGMA busy_timeout=5000; $1" 2>&1
}

card_ready() { [ -r "$BOOKS_DB" ]; }
reader_proc_alive() { pgrep -f "$READER_PROC" >/dev/null 2>&1; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || printf '0'; }

# The reader process survives after the user closes a book (verified: the
# process stayed alive through an entire test window), so "process alive"
# alone would block pulls until the next reboot. Treat the reader as BUSY
# (unsafe to pull) only if it is alive AND recently touched position state:
# the top-level last-opened position.cfg, or the book's own cfg dir.
# Lingering process + stale state = book closed = safe to apply the pull.
reader_busy() { # $1 = per-book cfg dir (optional); 0 = busy (skip pull)
  reader_proc_alive || return 1
  m=$(file_mtime "$READER_STATE_DIR/position.cfg")
  a=$(expr "$(now)" - "${m:-0}" 2>/dev/null)
  case "$a" in ''|*[!0-9]*) a=999999 ;; esac   # expr exits 1 on a 0 result; test the output, not the status
  [ "$a" -lt "$PULL_READER_BUSY_SEC" ] && return 0
  if [ -n "${1:-}" ]; then
    m=$(file_mtime "$1/position.cfg")
    a=$(expr "$(now)" - "${m:-0}" 2>/dev/null)
    case "$a" in ''|*[!0-9]*) a=999999 ;; esac
    [ "$a" -lt "$PULL_READER_BUSY_SEC" ] && return 0
  fi
  return 1
}

# --- HTTP (CWA KOSync) -------------------------------------------------------
# do_request METHOD PATH [BODY] -> sets REPLY_BODY and REPLY_CODE (http status)
do_request() {
  method=$1; url=$2; body=${3:-}
  REPLY_BODY=""; REPLY_CODE=0
  if [ -n "$body" ]; then
    out=$(curl -sS -u "$CWA_USER:$CWA_PASS" --max-time "$CURL_MAX" \
          -X "$method" -H 'Content-Type: application/json' \
          -d "$body" -w '\n__CODE__%{http_code}' "$url" 2>&1)
  else
    out=$(curl -sS -u "$CWA_USER:$CWA_PASS" --max-time "$CURL_MAX" \
          -X "$method" -w '\n__CODE__%{http_code}' "$url" 2>&1)
  fi
  rc=$?
  if [ $rc -ne 0 ]; then
    REPLY_BODY=$out; REPLY_CODE=$rc
    return $rc
  fi
  REPLY_CODE=$(printf '%s' "$out" | sed -n 's/.*__CODE__//p' | tail -n1)
  REPLY_BODY=$(printf '%s' "$out" | sed 's/__CODE__[0-9]*$//' | sed 's/[[:space:]]*$//')
  [ -n "$REPLY_CODE" ]
}

auth_ok() {
  do_request GET "$CWA_URL/kosync/users/auth"
  [ "${REPLY_CODE:-0}" = "200" ]
}

# Push one book's progress. $1=doc $2=progress $3=percentage
api_push() {
  # Sanitize: only characters safe inside a JSON string are expected, but be safe.
  # Internal vars use unique names (adoc/aprog): ash has no `local`, so a bare
  # `prog=` here would clobber the caller's $prog. That exact bug made the push
  # record the CFI (not the float) into the state, so push_due never matched.
  adoc=$(printf '%s' "$1" | sed 's/"/\\"/g')
  aprog=$(printf '%s' "$2" | sed 's/"/\\"/g')
  body=$(printf '{"document":"%s","progress":"%s","percentage":%s,"device":"%s","device_id":"%s"}' \
        "$adoc" "$aprog" "$3" "$DEVICE_NAME" "$DEVICE_ID")
  do_request PUT "$CWA_URL/kosync/syncs/progress" "$body"
}

# Fetch server progress for a doc. $1=doc -> REPLY_BODY (JSON), REPLY_CODE
api_get() {
  adoc=$(printf '%s' "$1" | sed 's/%/%25/g')
  do_request GET "$CWA_URL/kosync/syncs/progress/$adoc"
}
# Echo the GET-stored timestamp for a doc, or return 1. We anchor references
# to the GET scale because CWA's PUT response and GET use different clocks.
stored_ts() {
  api_get "$1" || return 1
  [ "${REPLY_CODE:-0}" = "200" ] || return 1
  t=$(json_get "$REPLY_BODY" timestamp)
  case "$t" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$t"; return 0 ;; esac
}

# --- state store -------------------------------------------------------------
# TSV: oid <TAB> digest <TAB> pushed_progress <TAB> pushed_position
#     <TAB> ref_ts (server GET scale, for the pull gate)
#     <TAB> dev_ts (device clock, for the push cooldown)
state_get() { # $1=oid -> ST_DIGEST ST_PPROG ST_PPOS ST_REFTS ST_DEVTS
  ST_DIGEST=""; ST_PPROG=""; ST_PPOS=""; ST_REFTS=0; ST_DEVTS=0
  line=$(awk -F'\t' -v k="$1" '$1==k{print; exit}' "$STATE_FILE" 2>/dev/null)
  [ -z "$line" ] && return 0
  ST_DIGEST=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
  ST_PPROG=$(printf '%s' "$line"  | awk -F'\t' '{print $3}')
  ST_PPOS=$(printf '%s' "$line"   | awk -F'\t' '{print $4}')
  ST_REFTS=$(printf '%s' "$line"  | awk -F'\t' '{print $5}')
  ST_DEVTS=$(printf '%s' "$line"  | awk -F'\t' '{print $6}')
  [ -n "$ST_REFTS" ] || ST_REFTS=0
  [ -n "$ST_DEVTS" ] || ST_DEVTS=0
}
state_set() { # $1=oid $2=digest $3=pprog $4=ppos $5=refts $6=devts
  awk -F'\t' -v OFS='\t' -v k="$1" '$1!=k' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-0}" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# --- per-book data -----------------------------------------------------------
book_progress()  { q_ro "SELECT COALESCE(Val,'') FROM Tags WHERE ItemID=$1 AND TagID=$TAG_PROGRESS;"; }
book_position()  { q_ro "SELECT COALESCE(Val,'') FROM Tags WHERE ItemID=$1 AND TagID=$TAG_POSITION;"; }
book_timeopened(){ q_ro "SELECT COALESCE(Val,'0') FROM Tags WHERE ItemID=$1 AND TagID=$TAG_TIMEOPENED;"; }
book_hashuuid()  { q_ro "SELECT COALESCE(HashUUID,'') FROM Items WHERE OID=$1;"; }
book_files() {
  q_ro "SELECT p.Path || f.Name FROM Files f JOIN Paths p ON p.OID=f.PathID
        WHERE f.BookID=$1 ORDER BY f.Ord;"
}

pick_target() { # $1=files(newline) $2=position -> one path
  files=$1; pos=$2
  if printf '%s' "$pos" | grep -q 'epubcfi\|/webkit'; then
    p=$(printf '%s\n' "$files" | grep -i '\.epub$' | head -n1)
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  fi
  if printf '%s' "$pos" | grep -q 'pdfloc\|/page'; then
    p=$(printf '%s\n' "$files" | grep -i '\.pdf$' | head -n1)
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  fi
  printf '%s\n' "$files" | head -n1
}

# The book's LOCAL reading position, from the store the native reader
# actually uses. explorer-3.db (books_settings) is primary — the reader
# resumes from it on open and writes back to it on close; books.db
# Tag80/81 is a legacy mirror that can be stale (the reader does NOT
# always update it), so it is only a fallback.
# Sets: LP_POS (pbr/CFI string), LP_PCT (0..1 float), LP_TARGET (file path).
local_progress() { # $1=oid
  LP_POS=""; LP_PCT=""; LP_TARGET=""
  lp_files=$(book_files "$1")
  [ -n "$lp_files" ] || return 1
  lp_dbpos=$(book_position "$1")
  lp_target=$(pick_target "$lp_files" "$lp_dbpos")
  [ -n "$lp_target" ] && [ -r "$lp_target" ] || return 1
  LP_TARGET=$lp_target
  lp_base=${lp_target##*/}
  if ex_ready; then
    lp_bid=$(ex_ro "SELECT book_id FROM files WHERE filename='$lp_base';" | head -n 1)
    if [ -n "$lp_bid" ]; then
      lp_epos=$(ex_ro "SELECT position FROM books_settings WHERE bookid=$lp_bid
                       AND position IS NOT NULL AND position != ''
                       ORDER BY COALESCE(position_ts,0) DESC LIMIT 1;" | head -n 1)
      if [ -n "$lp_epos" ]; then
        LP_POS=$lp_epos
        lp_cn=$(ex_ro "SELECT cpage||'|'||npage FROM books_settings WHERE bookid=$lp_bid
                       AND position IS NOT NULL AND position != ''
                       ORDER BY COALESCE(position_ts,0) DESC LIMIT 1;" | head -n 1)
        lp_cp=${lp_cn%%|*}; lp_np=${lp_cn##*|}
        case "$lp_cp" in ''|*[!0-9]*) lp_cp="" ;; esac
        case "$lp_np" in ''|*[!0-9]*) lp_np="" ;; esac
        if [ -n "$lp_cp" ] && [ -n "$lp_np" ]; then
          LP_PCT=$(awk -v a="$lp_cp" -v b="$lp_np" 'BEGIN{printf "%.17g", a/b}')
        fi
      fi
    fi
  fi
  [ -z "$LP_POS" ] && LP_POS=$lp_dbpos
  [ -z "$LP_PCT" ] && LP_PCT=$(book_progress "$1")
  [ -z "$LP_PCT" ] && LP_PCT=0
  [ -n "$LP_POS" ] && [ -n "$LP_PCT" ]
}

# Books that have a reading position somewhere: the books.db Tag80 set,
# unioned with explorer-3 books that have a position (mapped back to
# books.db oids by file name). Output: space-separated unique oids.
progress_oids() {
  a=$(q_ro "SELECT DISTINCT ItemID FROM Tags WHERE TagID=$TAG_PROGRESS ORDER BY ItemID;")
  b=""
  if ex_ready; then
    ex_ro "SELECT DISTINCT f.filename FROM files f
           JOIN books_settings bs ON bs.bookid=f.bookid
           WHERE bs.position IS NOT NULL AND bs.position != '';" > "$AGENT_DIR/.fnames" 2>/dev/null
    if [ -f "$AGENT_DIR/.fnames" ]; then
      while IFS= read -r fn; do
        [ -n "$fn" ] || continue
        fnq=$(sql_quote "$fn")
        oid=$(q_ro "SELECT i.OID FROM Items i JOIN Files f ON f.BookID=i.OID
                    WHERE f.Name='$fnq' LIMIT 1;")
        [ -n "$oid" ] && b="$b $oid"
      done < "$AGENT_DIR/.fnames"
    fi
    rm -f "$AGENT_DIR/.fnames" 2>/dev/null
  fi
  { printf '%s\n' "$a"; printf '%s\n' "$b"; } | awk 'NF' | sort -n -u | tr '\n' ' '
}

# --- push --------------------------------------------------------------------
# A book is "due" for push when its LOCAL POSITION differs from what we last
# pushed AND the per-book cooldown has elapsed. The percentage float is
# derived data (different writers format it differently), so only the
# position (normalized) decides. Local-only, no network.
push_due() { # $1=oid -> 0 if due
  local_progress "$1" || return 1
  state_get "$1"
  [ -n "$ST_DIGEST" ] || return 0   # never synced -> push to establish baseline
  lp=$(norm_loc "$LP_POS")
  sp=$(norm_loc "$ST_PPOS")
  [ "$lp" = "$sp" ] && return 1   # same reading position as last sync
  if [ "${ST_DEVTS:-0}" -gt 0 ] 2>/dev/null; then
    age=$(expr "$(now)" - "$ST_DEVTS" 2>/dev/null)
    case "$age" in ''|*[!0-9]*) age=999999 ;; esac  # expr exits 1 when the result is 0; test the output
    [ "$age" -lt "$PUSH_COOLDOWN" ] && return 1
  fi
  return 0
}

# Iterate books that have progress and push any that changed locally.
cmd_push() {
  card_ready || { log "push: card not ready ($BOOKS_DB unreadable)"; return 1; }
  log "push: scanning library"
  oids=$(progress_oids)
  [ -n "$oids" ] || { log "push: no books with progress"; return 0; }
  n=0; pushed=0
  for oid in $oids; do
    n=$(expr "$n" + 1)
    push_due "$oid" || continue
    local_progress "$oid" || continue
    prog=$LP_PCT
    pos=$LP_POS
    target=$LP_TARGET
    digest=$(partial_md5 "$target")
    [ -n "$digest" ] || { log "push[$oid]: digest failed for $target"; continue; }
    # Choose the progress locator to send (KOSync-friendly).
    if printf '%s' "$pos" | grep -q 'epubcfi'; then
      loc=$(extract_cfi "$pos")
    else
      page=$(extract_page "$pos")
      if [ -n "$page" ]; then loc="page=$page"; else loc=$pos; fi
    fi
    [ -n "$loc" ] || loc=$pos
    if api_push "$digest" "$loc" "$prog"; then
      if [ "${REPLY_CODE:-0}" = "200" ] || [ "${REPLY_CODE:-0}" = "202" ]; then
        # Anchor the reference on the GET scale (what the pull reads), NOT the
        # PUT-response ts: CWA's PUT response and GET report different clocks
        # (the GET value lags here), so a PUT-response reference would sit
        # ahead of every future GET and permanently block the pull gate.
        put_ts=$(json_get "${REPLY_BODY}" timestamp)
        srv_ts=$(stored_ts "$digest")
        case "$srv_ts" in ''|*[!0-9]*)
          case "$put_ts" in ''|*[!0-9]*) srv_ts=0 ;; *) srv_ts=$(expr "$put_ts" - 3600 2>/dev/null) ;; esac ;; esac
        state_set "$oid" "$digest" "$prog" "$pos" "$srv_ts" "$(now)"
        pushed=$(expr "$pushed" + 1)
        log "push[$oid]: ok (ts=$srv_ts) -> ${REPLY_BODY:-}"
      else
        log "push[$oid]: HTTP ${REPLY_CODE}: ${REPLY_BODY:-}"
      fi
    else
      log "push[$oid]: curl/network error (${REPLY_CODE}): ${REPLY_BODY:-}"
      # Stop on network failure to avoid hammering an offline endpoint.
      return 1
    fi
  done
  log "push: done (books=$n pushed=$pushed)"
  return 0
}

# --- pull --------------------------------------------------------------------
ensure_db_backup() {
  if [ ! -f "$DB_BACKUP" ] && [ -f "$BOOKS_DB" ]; then
    cp -f "$BOOKS_DB" "$DB_BACKUP" 2>/dev/null && log "pull: created db backup $DB_BACKUP"
  fi
}

sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

upsert_tag() { # $1=oid $2=tagid $3=value
  val=$(sql_quote "$3")
  n=$(q_ro "SELECT COUNT(*) FROM Tags WHERE ItemID=$1 AND TagID=$2;")
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    q_rw "UPDATE Tags SET Val='$val', TimeEdt=$(now) WHERE ItemID=$1 AND TagID=$2;" >/dev/null
  else
    no=$(q_ro "SELECT COALESCE(MAX(OID),0)+1 FROM Tags;")
    q_rw "INSERT INTO Tags(OID,ItemID,TagID,Val,TimeEdt) VALUES($no,$1,$2,'$val',$(now));" >/dev/null
  fi
}

write_position_cfg() { # $1=dir $2=pbr
  mkdir -p "$1" 2>/dev/null
  {
    printf 'is_scroll=0\nscreen=0\nsection=0\nsection_offset=0\n'
    printf 'text=%s\nx=0\ny=0\n' "$2"
  } > "$1/position.cfg"
  # The reader validates the trailing "#<crc32>" line (crc32 of the content
  # above it). Compute it and append.
  sum=$(crc32_file "$1/position.cfg")
  if [ -n "$sum" ]; then
    printf '#%s\n' "$sum" >> "$1/position.cfg"
  else
    rm -f "$1/position.cfg" 2>/dev/null
    return 1
  fi
}

# Write the pulled position into the native reader's canonical store
# (explorer-3.db books_settings). cpage comes from an explicit page in the
# position (PDFs) or round(percentage * npage) (EPUBs); the reader resumes
# from position, cpage is auxiliary.
ex_apply() { # $1=oid $2=target $3=pbr $4=spct
  ex_ready || { log "pull[$1]: explorer db not ready; skipped"; return 1; }
  ex_base=${target##*/}
  ex_t=$(now)
  ex_val=$(sql_quote "$3")
  ex_bids=$(ex_ro "SELECT book_id FROM files WHERE filename='$ex_base';" | tr '\n' ' ')
  [ -n "$ex_bids" ] || { log "pull[$1]: no explorer-3 book_id for $ex_base; skipped"; return 1; }
  for ex_bid in $ex_bids; do
    ex_line=$(ex_ro "SELECT cpage||'|'||npage FROM books_settings WHERE bookid=$ex_bid LIMIT 1;")
    ex_cp=${ex_line%%|*}; ex_np=${ex_line##*|}
    case "$ex_cp" in ''|*[!0-9]*) ex_cp="" ;; esac
    case "$ex_np" in ''|*[!0-9]*) ex_np="" ;; esac
    ex_page=$(extract_page "$3")
    case "$ex_page" in ''|0) : ;; *) ex_cp=$ex_page ;; esac
    if [ -z "$ex_cp" ] && [ -n "$ex_np" ] && [ -n "$4" ]; then
      ex_cp=$(awk -v p="$4" -v n="$ex_np" 'BEGIN{v=int(p*n+0.5); if(v<1)v=1; print v}')
    fi
    ex_n=$(ex_ro "SELECT COUNT(*) FROM books_settings WHERE bookid=$ex_bid;")
    if [ "${ex_n:-0}" -gt 0 ] 2>/dev/null; then
      if [ -n "$ex_cp" ]; then
        ex_rw "UPDATE books_settings SET position='$ex_val', position_ts=$ex_t, cpage=$ex_cp, opentime=$ex_t WHERE bookid=$ex_bid;" >/dev/null
      else
        ex_rw "UPDATE books_settings SET position='$ex_val', position_ts=$ex_t, opentime=$ex_t WHERE bookid=$ex_bid;" >/dev/null
      fi
    else
      ex_cp_sql=${ex_cp:-NULL}; ex_np_sql=${ex_np:-NULL}
      ex_rw "INSERT INTO books_settings(bookid, profileid, position, position_ts, cpage, npage, opentime)
             VALUES($ex_bid, 1, '$ex_val', $ex_t, $ex_cp_sql, $ex_np_sql, $ex_t);" >/dev/null
    fi
  done
}

# Apply server progress to the device for one book.
apply_pull() { # $1=oid $2=target $3=server_progress $4=server_percentage $5=server_ts
  oid=$1; target=$2; sprog=$3; spct=$4; sts=$5
  # Build a pbr: URI the native reader understands, based on the format.
  case "$target" in
    *.pdf)
      ap_page=$(extract_page "$sprog")
      if [ -z "$ap_page" ]; then
        case "$sprog" in
          ''|*[!0-9]*) ap_page=0 ;;
          *) ap_page=$sprog ;;
        esac
      fi
      APPLIED_PBR="pbr:/page?page=${ap_page:-0}"
      ;;
    *)
      ap_cfi=$(extract_cfi "$sprog")
      [ -n "$ap_cfi" ] || ap_cfi=$sprog
      APPLIED_PBR="pbr:/webkit?##epubcfi($ap_cfi)"
      ;;
  esac
  ap_hashu=$(book_hashuuid "$oid")
  ensure_db_backup
  # books.db legacy mirror (Tag80 = 0..1 float, Tag81 = pbr URI, Tag42 = epoch).
  upsert_tag "$oid" "$TAG_PROGRESS" "$spct"
  upsert_tag "$oid" "$TAG_POSITION" "$APPLIED_PBR"
  # Tag42 (time_opened) is a real epoch; this CWA reports UTC-3600.
  real_ts=$(expr "$sts" + 3600 2>/dev/null) || real_ts=0
  case "$real_ts" in ''|*[!0-9]*|0) real_ts=$(now) ;; esac
  upsert_tag "$oid" "$TAG_TIMEOPENED" "$real_ts"
  # explorer-3 — the store the reader actually resumes from (primary).
  ex_apply "$oid" "$target" "$APPLIED_PBR" "$spct"
  # per-book reader cfg (kept consistent; the reader overwrites it on close)
  if [ -n "$ap_hashu" ]; then
    write_position_cfg "$READER_STATE_DIR/$(printf '%s' "$ap_hashu" | tr 'A-Z' 'a-z')" "$APPLIED_PBR"
  fi
  log "pull[$oid]: applied -> $APPLIED_PBR (pct=$spct ts=$sts)"
}

cmd_pull() {
  card_ready || { log "pull: card not ready"; return 1; }
  # NOTE: no global reader guard here — the reader process lingers after the
  # user closes a book. Per-book busy check (reader_busy) happens right before
  # applying each pull, so a closed book still syncs while an actively open
  # one is protected.
  oids=$(progress_oids)
  [ -n "$oids" ] || { log "pull: no books with progress"; return 0; }
  pulled=0
  for oid in $oids; do
    state_get "$oid"
    local_progress "$oid" || continue
    pos=$LP_POS
    target=$LP_TARGET
    digest=$(partial_md5 "$target")
    [ -n "$digest" ] || continue
    api_get "$digest" || continue
    [ -n "$REPLY_BODY" ] || continue
    spct=$(json_get "$REPLY_BODY" percentage)
    sprog=$(json_get "$REPLY_BODY" progress)
    sts=$(json_get "$REPLY_BODY" timestamp)
    [ -n "$spct" ] || continue            # no server record for this book
    # Only pull if the server is newer than our last sync reference AND the
    # position actually differs (formats compared after normalization).
    case "$sts" in ''|*[!0-9]*) sts=0 ;; esac
    [ "$sts" -gt "${ST_REFTS:-0}" ] 2>/dev/null || continue
    sn=$(norm_loc "$sprog"); ln=$(norm_loc "$pos")
    [ "$sn" = "$ln" ] && continue
    hu=$(book_hashuuid "$oid")
    bdir=""; [ -n "$hu" ] && bdir="$READER_STATE_DIR/$(printf '%s' "$hu" | tr 'A-Z' 'a-z')"
    if reader_busy "$bdir"; then
      log "pull[$oid]: reader busy (state fresh within ${PULL_READER_BUSY_SEC}s); skipping"
      continue
    fi
    apply_pull "$oid" "$target" "$sprog" "$spct" "$sts"
    # Record the NEW (pulled) values so push_due sees them as already-synced.
    state_set "$oid" "$digest" "$spct" "$APPLIED_PBR" "$sts" "$(now)"
    pulled=$(expr "$pulled" + 1)
  done
  log "pull: done (pulled=$pulled)"
  return 0
}

# --- commands ----------------------------------------------------------------
cmd_once() {
  trim_log
  cmd_push
  if [ "$PULL_ENABLED" = "1" ]; then cmd_pull; fi
}

# Local-only check: is any book due for push (changed AND cooldown elapsed)?
# No network involved. Used to gate the push so we do not keep WiFi awake
# polling an idle device.
local_pending_push() {
  card_ready || return 1
  oids=$(progress_oids)
  [ -n "$oids" ] || return 1
  for oid in $oids; do
    push_due "$oid" && return 0
  done
  return 1
}

cmd_loop() {
  # Guard: treat the pid file as live only if that pid is actually THIS script.
  # After a reboot the OS reuses pids; an innocent process (e.g. sshd) holding
  # the old number must not block startup.
  if [ -f "$PID_FILE" ]; then
    oldpid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null && grep -q pbkosync "/proc/$oldpid/cmdline" 2>/dev/null; then
      echo "pb-kosync: already running (pid $oldpid)" >&2
      return 1
    fi
  fi
  printf '%s' "$$" > "$PID_FILE"
  # Only remove the pid file if it still belongs to US: a stale instance's
  # deferred trap must not clobber a newer daemon's pid file.
  trap 'if [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then rm -f "$PID_FILE"; fi; log "loop: stopped (signal)"; exit 0' INT TERM
  log "loop: started pid=$$ poll=${POLL_SEC}s pull=${PULL_SEC}s pull_enabled=$PULL_ENABLED url=$CWA_URL"
  last_pull=0
  offline_streak=0
  while :; do
    if card_ready; then
      # Push: only touch the network if a local change is actually pending.
      if local_pending_push; then
        if auth_ok; then
          offline_streak=0
          cmd_push
        else
          offline_streak=$(expr "$offline_streak" + 1)
          if [ "$offline_streak" -le 1 ] || [ "$(expr "$offline_streak" % 20)" -eq 0 ]; then
            log "loop: push pending but offline/auth failed (${REPLY_CODE:-?}): ${REPLY_BODY:-}"
          fi
        fi
      fi
      # Pull: on an interval, regardless of push state (reader-idle guarded inside).
      n=$(now)
      if [ "$PULL_ENABLED" = "1" ]; then
        dl=$(expr "$n" - "$last_pull" 2>/dev/null)
        case "$dl" in ''|*[!0-9]*) dl=999999 ;; esac  # expr exits 1 when the result is 0; test the output
        if [ "$dl" -ge "$PULL_SEC" ]; then
          if auth_ok; then
            offline_streak=0
            cmd_pull
          fi
          last_pull=$n
        fi
      fi
    fi
    trim_log
    sleep "$POLL_SEC"
  done
}

cmd_check_auth() {
  if auth_ok; then
    echo "OK: authenticated to $CWA_URL (code 200)"
    log "check-auth: OK"
    return 0
  fi
  echo "FAIL: auth to $CWA_URL -> code=${REPLY_CODE:-?} body=${REPLY_BODY:-}"
  log "check-auth: FAIL code=${REPLY_CODE:-?} body=${REPLY_BODY:-}"
  return 1
}

cmd_status() {
  echo "CWA_URL=$CWA_URL"
  echo "DEVICE_NAME=$DEVICE_NAME  DEVICE_ID=$DEVICE_ID"
  echo "POLL_SEC=$POLL_SEC PULL_SEC=$PULL_SEC PULL_ENABLED=$PULL_ENABLED"
  echo "DATA_DIR=$DATA_DIR"
  echo "BOOKS_DB=$BOOKS_DB"
  echo "EXPLORER_DB=$EXPLORER_DB ready=$(ex_ready && echo yes || echo no)"
  echo "reader_proc_alive=$(reader_proc_alive && echo yes || echo no) busy_sec=$PULL_READER_BUSY_SEC"
  echo "card_ready=$(card_ready && echo yes || echo no)"
  echo "-- state (oid digest pushed_pct pushed_pos ref_ts dev_ts) --"
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" | sed 's/\t/ | /g'
  echo "-- last log --"
  tail -n 15 "$LOG_FILE" 2>/dev/null
  echo "-- pid --"
  [ -f "$PID_FILE" ] && { pid=$(cat "$PID_FILE"); echo "pid=$pid running=$(kill -0 "$pid" 2>/dev/null && grep -q pbkosync "/proc/$pid/cmdline" 2>/dev/null && echo yes || echo no)"; } || echo "not running"
}

cmd_digest() {
  [ -n "${1:-}" ] || { echo "usage: $0 digest <file>" >&2; return 2; }
  partial_md5 "$1"
}

# No-network diagnostics: show what the push side WOULD see for each book
# that has a local reading position. Useful for verifying the local stores
# (explorer-3 vs books.db) without touching CWA. Optional: specific oids.
cmd_localcheck() {
  echo "card_ready=$(card_ready && echo yes || echo no)  ex_ready=$(ex_ready && echo yes || echo no)"
  echo "BOOKS_DB=$BOOKS_DB"
  echo "EXPLORER_DB=$EXPLORER_DB"
  if [ -n "${1:-}" ]; then
    oids=$*
  else
    oids=$(progress_oids)
  fi
  [ -n "$oids" ] || { echo "no oids"; return 0; }
  for oid in $oids; do
    echo "=== oid $oid ==="
    if local_progress "$oid"; then
      echo "  local_pos  = $LP_POS"
      echo "  local_pct  = $LP_PCT"
      echo "  local_file = $LP_TARGET"
    else
      echo "  local_progress FAILED (rc=$?) — missing/unreadable file or no position"
    fi
    state_get "$oid"
    if [ -n "$ST_DIGEST" ]; then
      echo "  state_pos  = $ST_PPOS  (pushed_pct=$ST_PPROG ref_ts=$ST_REFTS dev_ts=$ST_DEVTS)"
      if push_due "$oid"; then echo "  push_due   = DUE"; else echo "  push_due   = not-due (rc=$?)"; fi
    else
      echo "  state      = (never synced)"
      if push_due "$oid"; then echo "  push_due   = DUE (baseline)"; else echo "  push_due   = not-due"; fi
    fi
  done
}

# --- dispatch ----------------------------------------------------------------
cmd=${1:-}
case "$cmd" in
  push)         card_ready && cmd_push ;;
  pull)         card_ready && cmd_pull ;;
  once)         cmd_once ;;
  loop)         cmd_loop ;;
  check-auth)   cmd_check_auth ;;
  localcheck)   shift; cmd_localcheck "$@" ;;
  status)       cmd_status ;;
  digest)       cmd_digest "${2:-}" ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && grep -q pbkosync "/proc/$pid/cmdline" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        # ash defers a trapped TERM until the foreground `sleep` child exits,
        # so wait for the process to actually go (bounded), then force if needed.
        i=0
        while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
          sleep 1
          i=$(expr "$i" + 1)
        done
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null
          sleep 1
        fi
        if kill -0 "$pid" 2>/dev/null; then
          echo "WARNING: pid $pid still alive"
        else
          echo "stopped pid $pid"
        fi
      else
        echo "stale pid file ($pid); nothing killed"
      fi
      rm -f "$PID_FILE"
    else
      echo "not running"
    fi
    ;;
  *)
    echo "usage: $0 {push|pull|once|loop|check-auth|localcheck [oid...]|status|digest <file>|stop}" >&2
    exit 2
    ;;
esac

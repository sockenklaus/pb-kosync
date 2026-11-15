# pb-kosync

Bidirectional read-progress sync between the **PocketBook Era Color's native
reader** and **Calibre-Web-Automated (CWA)**, using the KOReader **KOSync**
protocol — no KOReader reader on the device, no extra server.

```
PocketBook Era Color (native reader)
  explorer-3.db books_settings   ← canonical resume store (reader resumes here)
  books.db: doc.read_progress / doc.last_read_position   (kept in sync)
  system/state/cache/reader/<hash>/position.cfg          (kept in sync, CRC32-checked)
        ▲                                   │
        │ pull (CWA record is newer)        │ push (device changed)
        │                                   ▼
    CWA /kosync API  ←── PUT/GET /kosync/syncs/progress
    (Calibre reading status updates as a side effect)
```

## How it works

- **Book identity** is the KOReader *partial MD5* digest (12 × 1 KiB samples
  at fixed file offsets, MD5'd). Implemented with `dd` + `md5sum`, verified
  byte-identical against a digest KOReader itself stored on this card
  (`Metro 2034` → `25216c1c…4445b153`). CWA generates the same digest for
  library books, so both sides resolve the *same* book.
- **Where the reader actually resumes from** (verified on-device, the original
  bug): the native reader resumes from
  `system/explorer-3/explorer-3.db` → `books_settings` (`position`, `cpage`,
  `npage`, `position_ts`) — **not** from `books.db`. Writing `books.db` /
  `position.cfg` alone changed nothing about where the reader reopened the
  book. So the agent writes **all three** stores and reads the local position
  from `explorer-3` first (`books.db` as fallback).
- **Push**: for each book that has progress (books.db `TagID=80`), the agent
  compares the current local position with the last synced reference and
  `PUT /kosync/syncs/progress` with `{document, progress, percentage, device,
  device_id}`. For EPUB it sends the CFI (extracted from PB's
  `pbr:/…#epubcfi(…)` URI); for PDF it sends `page=N`. Only books whose
  normalized position actually differs are pushed; a per-book cooldown
  (default 90 s) prevents a push per page-turn.
- **Pull**: when the server record is newer (timestamps compared on CWA's GET
  scale — see quirk below) and the position actually differs (formats
  normalized before comparing), the agent applies the position to all three
  stores: `explorer-3.db` (UPSERT into `books_settings`; `cpage` from an
  explicit page for PDFs or `round(percentage × npage)` for EPUBs),
  `books.db` (`read_progress` float, `last_read_position` pbr URI,
  `time_opened`), and the per-book `position.cfg` — including the trailing
  `#<crc32>` line the reader validates (CRC32 implemented in awk, verified
  against reader-written files).
- **New-book adoption** (downloaded via OPDS, already read on another device):
  KOSync has no "list my progress" endpoint, so the agent discovers books by
  computing the digest of every local library file. Each pull cycle it consults
  the server for books it has *never* synced: if CWA holds a position, it is
  adopted into all three stores (so the reader resumes where the phone left
  off); if CWA is empty the book is marked "cleared" so a later local read can
  still push a baseline. This always runs **before** any push, so opening a
  book on the device can never push a fresh page 1 over the phone's saved
  position. Each book is probed only once (adopted or cleared), keeping the
  network cost to a single GET per new book. Actively-open books are never
  yanked (same busy guard as pulls).
- **Reader-busy guard**: the reader process lingers after a book is closed,
  so "process alive" alone would block pulls for hours. A pull for a book is
  skipped only while the reader process (`READER_PROC`, default
  `eink-reader`) is alive **and** that book's position state changed within
  `PULL_READER_BUSY_SEC` (120 s) — i.e. during active reading. Lingering
  process + stale state = book closed = safe to apply.
- **CWA clock quirk** (observed 3× on this setup): the PUT-response
  timestamp and the GET timestamp of the *same* record come from different
  clocks — here the GET value is exactly 3600 s behind. The agent therefore
  anchors all sync references on the **GET scale**: after a push it re-reads
  the record's GET ts (falling back to `put_ts − 3600`), and the pull gate
  compares GET scale against GET scale.
- **Battery-friendly loop**: every poll is local-only (sqlite + state file);
  the network is touched only when a push is pending or the pull interval
  elapsed.
- **Safety**: first mutating write backs up `books.db` to `books.db.bak`;
  all library-DB reads go through `file:…?mode=ro`; the log is trimmed at
  4000 lines.
- **Robustness**: the single-instance guard checks that the pid in `.pid` is
  actually this script (`/proc/<pid>/cmdline`) — a reused pid (common right
  after a reboot, e.g. sshd) must not block startup. `stop` waits for the
  process to truly exit (bounded, SIGKILL fallback) because busybox ash
  defers a trapped `TERM` while its `sleep` child runs; the exit trap removes
  the pid file only if it still belongs to itself.

## Files

| File | Purpose |
|---|---|
| `pbkosync.sh` | the agent (POSIX sh; busybox + curl + sqlite3 only) |
| `config` | your CWA URL/account/password + tuning (keep private; git-ignored) |
| `config.example` | template with all knobs documented |
| `deploy.sh` | deploy / undeploy / start over SSH |
| `state`, `log`, `.pid`, `.id`, `books.db.bak` | created at runtime (device or local) |

## Setup

```sh
cp config.example config      # fill in CWA_URL / CWA_USER / CWA_PASS
./deploy.sh                   # copy to device, add boot hook in /etc/init.d/rcS
# verify credentials:
ssh root@192.168.205.1 '/mnt/secure/pb-kosync/pbkosync.sh check-auth'
./deploy.sh start             # deploy + start daemon now
```

On the device (via SSH, USB mode only):

```sh
/mnt/secure/pb-kosync/pbkosync.sh status      # config, state, log, pid
/mnt/secure/pb-kosync/pbkosync.sh once        # one adopt+push+pull now
/mnt/secure/pb-kosync/pbkosync.sh adopt       # adopt never-synced books from the server
/mnt/secure/pb-kosync/pbkosync.sh push        # push only
/mnt/secure/pb-kosync/pbkosync.sh pull        # pull only
/mnt/secure/pb-kosync/pbkosync.sh localcheck [oid…]   # offline position diagnostics
/mnt/secure/pb-kosync/pbkosync.sh loop        # daemon (self-guarding)
/mnt/secure/pb-kosync/pbkosync.sh check-auth  # CWA auth probe
/mnt/secure/pb-kosync/pbkosync.sh stop        # stop the daemon
/mnt/secure/pb-kosync/pbkosync.sh digest FILE # partial-MD5 of a file
```

CWA side: enable **KOReader Sync** in Settings so it backfills the
KOReader-compatible checksums for the library. Use a (dedicated) CWA account
for the agent; progress is stored per CWA user. Keep any *real* KOReader
instance's own sync **off** — two writers for the same books fight.

## Verified (2026-11-15, PocketBook Era Color, OS 6.10.2359)

- **Push**: local 23.5 % (`/6/18!/4/50/1`) landed on CWA from the device,
  attributed to the PocketBook.
- **Pull + resume**: a CWA record set to 0.6655 % (`/6/6!/1`) was applied
  while the reader was idle; opening the book then resumed at that spot
  (~page 3) instead of the old 23.6 % position — proving `explorer-3.db` is
  the store the reader resumes from.
- **Live reading sync**: the position read on the device was pushed back to
  CWA automatically.
- **Busy guard**: with the book open (page 73), a newer CWA position
  (page 71) was *not* applied; the reader stayed where it was.

## Known constraints

- Sync needs Wi-Fi: in USB/mass-storage mode the device has no network and
  the SD card is handed to the PC; the agent idles and drains after the
  reboot back into Wi-Fi (the mode switch is a reboot; the boot hook
  restarts the daemon).
- Book identity needs the *same file bytes* on both sides (true for books
  served/downloaded from CWA). Transcoded copies require a server-side
  filename-based match instead.
- The boot hook is appended to `/etc/init.d/rcS` on the device (markers
  `#pb-kosync-start` … `#pb-kosync-end`); an OS update that replaces the
  rootfs could drop it — re-run `./deploy.sh` after such an update.
- Progress only (percentage + CFI/page position). Highlights/annotations are
  not part of the KOSync path.

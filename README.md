# pb-kosync

Bidirectional read-progress sync between the **PocketBook Era Color's native
reader** and **Calibre-Web-Automated (CWA)**, using the KOReader **KOSync**
protocol — no KOReader reader on the device, no extra server.

```
PocketBook Era Color (native reader)
  books.db: doc.read_progress / doc.last_read_position
  system/state/cache/reader/<hash>/position.cfg
        ▲                                   │
        │ pull (CWA is newer)               │ push (device changed)
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
- **Push**: the agent notices `doc.read_progress` / `doc.last_read_position`
  changed in `books.db`, computes the digest, and
  `PUT /kosync/syncs/progress` with `{document, progress, percentage,
  device, device_id}`. For EPUB it sends the CFI (extracted from PB's
  `pbr:/…#epubcfi(…)` URI); for PDF it sends `page=N`.
- **Pull**: when the server record is newer and the position actually differs
  (formats normalized before comparing), the agent writes
  `doc.read_progress` / `doc.last_read_position` back into `books.db` **and**
  rewrites the reader state `position.cfg` — including the trailing
  `#<crc32>` checksum line the reader validates (CRC32 implemented in awk,
  verified against reader-written files). Pulling is skipped while the native
  reader is running, so it never clobbers an open book.
- **Battery-friendly loop**: every poll is local-only (sqlite + state file).
  The network is touched only when a change is pending (push) or the pull
  interval elapsed. A per-book cooldown (default 90 s) prevents a push
  per page-turn.
- **Safety**: first pull-write backs up `books.db` to `books.db.bak`;
  read access to the library DB is always via `file:…?mode=ro`.

## Files

| File | Purpose |
|---|---|
| `pbkosync.sh` | the agent (POSIX sh; busybox + curl + sqlite3 only) |
| `config` | your CWA URL/account/password (keep private) |
| `config.example` | template |
| `deploy.sh` | deploy / undeploy / start over SSH |
| `state`, `log`, `.pid`, `.id`, `books.db.bak` | created on the device at runtime |

## Setup

```sh
cp config.example config      # fill in CWA_URL / CWA_USER / CWA_PASS
./deploy.sh                   # copy to device, add boot hook in /etc/init.d/rcS
# verify credentials:
ssh … 'root@192.168.205.1 /mnt/secure/pb-kosync/pbkosync.sh check-auth'
./deploy.sh start             # deploy + start daemon now
```

On the device (via SSH):

```sh
/mnt/secure/pb-kosync/pbkosync.sh status     # config, state, log, pid
/mnt/secure/pb-kosync/pbkosync.sh once       # one push+pull now
/mnt/secure/pb-kosync/pbkosync.sh push       # push only
/mnt/secure/pb-kosync/pbkosync.sh pull       # pull only
/mnt/secure/pb-kosync/pbkosync.sh stop       # stop the daemon
/mnt/secure/pb-kosync/pbkosync.sh digest FILE  # partial-MD5 of a file
```

CWA side: enable **KOReader Sync** in Settings so it backfills the
KOReader-compatible checksums for the library. Use a (dedicated) CWA account
for the agent; progress is stored per CWA user.

## Undeploy

```sh
./deploy.sh undeploy          # removes boot hook + installed files
```

## Known constraints

- Sync happens while the SD card is in the reader. With the card exposed to
  the PC (USB mass storage) the device unmounts it; the agent simply waits
  and drains when the card is back.
- Book identity needs the *same file bytes* on both sides (true for books
  served/downloaded from CWA). Transcoded copies require a server-side
  filename-based match instead.
- The boot hook is appended to `/etc/init.d/rcS` on the device (markers
  `#pb-kosync-start` … `#pb-kosync-end`); an OS update that replaces the
  rootfs could drop it — re-run `./deploy.sh` after such an update.
- Progress only (percentage + CFI/page position). Highlights/annotations are
  not part of the KOSync path.

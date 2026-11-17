# pb-kosync

> **Disclaimer:** This project was entirely vibe-coded with [Qwen3.8-27b](https://huggingface.co/Qwen/Qwen3-8B). I didn't write a single line of code.

## What it does

Bidirectional read-progress sync between the **PocketBook Era Color** native reader and [**Calibre-Web Automated (CWA)**](https://github.com/crocodilestick/Calibre-Web-Automated) over the [kosync](https://github.com/pid1/kosync-conformance) protocol.

- **Push**: when you read on the device, the position is sent to CWA (with a 90 s cooldown and a regression guard so a page-1 reset can't clobber your real progress).
- **Pull**: when CWA has a newer position (e.g. you read on your phone), the agent writes it into the reader's canonical store so the device resumes at the right page.
- **Adopt**: books downloaded from CWA that were already read elsewhere are picked up on first sync.
- **Shutdown flush**: the agent runs a final sync when the device powers off, so a comic-reading burst isn't lost to the cooldown.

Works with EPUB (CFI), PDF (page), and CBZ/CBR (page) books. No KOReader needed.

## Install

### 1. Unlock developer mode (one-time)

The agent runs over root SSH. PocketBook ships with SSH disabled; you must enable it once via a privilege-escalation exploit.

1. Install [pbterm](https://github.com/leomeyer/pbterm) (pick the release matching your SoC), copy it to `ext1/applications/` and launch it.
2. In pbterm, run:
   ```sh
   sh -c '/usr/cramfs/bin/iv2sh WriteConfig /mnt/secure/developer_mode privesc 1'
   ```
3. Reboot the device.
4. Connect via USB, then:
   ```sh
   ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.205.1
   ```

Source: [MobileRead thread](https://www.mobileread.com/forums/showthread.php?t=371671).

### 2. Deploy the agent

```sh
cp config.example config   # fill in CWA_URL, CWA_USER, CWA_PASS
./deploy.sh                # copies files to device, adds boot hook, starts daemon
```

On the CWA side: enable **KOReader Sync** in Settings. Use a dedicated CWA account — progress is per-user.

### 3. Verify

```sh
ssh root@192.168.205.1 '/mnt/secure/pb-kosync/pbkosync.sh status'
```

## What it changes on the PocketBook

| Change | Location | Reversible? |
|--------|----------|-------------|
| Agent script | `/mnt/secure/pb-kosync/pbkosync.sh` | `./deploy.sh undeploy` |
| Config (CWA credentials) | `/mnt/secure/pb-kosync/config` | delete file |
| Boot hook (auto-start) | `/etc/init.d/rcS` (lines appended between `#pb-kosync-start`/`#pb-kosync-end`) | `./deploy.sh undeploy` |
| Shutdown hook (final sync) | `/etc/init.d/rc.shutdown` (lines 5–7, between `#pb-kosync-flush`/`#pb-kosync-flush-end`) | restore from `/mnt/secure/pb-kosync/rc.shutdown.bak-flush` |
| Runtime state, log, pid | `/mnt/secure/pb-kosync/{state,log,.pid,.id}` | safe to delete |

Backups of the original `rcS` and `rc.shutdown` are kept in `/mnt/secure/pb-kosync/`. An OS update may reset developer mode and drop the `/etc` hooks — re-run `./deploy.sh` after an update.

## License

[MIT](LICENSE)

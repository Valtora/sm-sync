# Scrap Mechanic Sync

Shares one Scrap Mechanic Survival save between players through a Cloudflare R2 bucket.
A state file in the bucket records who has the world checked out. Only that player can
play and upload, so two copies can never go out of sync.

## Files

| File | Purpose |
| --- | --- |
| `Scrap Mechanic Sync.cmd` | Double-click this. Opens the menu in Windows Terminal when it is installed, otherwise in a normal console. |
| `sm-sync.ps1` | The tool. Runs on Windows PowerShell 5.1 and PowerShell 7. |
| `sm-sync.config.example.json` | Template for the settings file. |
| `sm-sync.config.json` | The real settings: R2 keys and the GitHub update token. Untracked, never commit it. |
| `FRIEND-INSTRUCTIONS.txt` | Plain instructions for the other player. |
| `dev\make-friend-zip.ps1` | Builds the zip you send to the other player. |
| `dev\simulate-friend.ps1` | Runs that zip as a second player on this PC. |
| `dev\test\run-tests.ps1` | End-to-end tests against a local stand-in for R2 and GitHub. |

## Setup

### 1. R2 bucket and keys

1. In the Cloudflare dashboard open **R2 Object Storage** and create a bucket.
2. **Manage API Tokens**, **Create API Token**: permission **Object Read & Write**,
   scoped to that bucket only.
3. Put the Access Key ID, the Secret Access Key and the S3 endpoint
   (`https://<account id>.r2.cloudflarestorage.com`, without the bucket name) into
   `sm-sync.config.json`. `SaveName` is the world's file name without `.db`.

### 2. GitHub update token

The other player's copy updates itself from this private repo, so it needs a read-only
token.

1. GitHub, **Settings**, **Developer settings**, **Fine-grained tokens**, **Generate new token**.
2. Repository access: **Only select repositories**, pick `sm-sync`.
3. Permissions: **Contents: Read-only**. Nothing else.
4. Expiry: your choice. With an expiry date, updates stop on that day until you issue a
   new token. Without one, a leaked zip stays usable until you delete the token.
5. Paste it into `GitHubToken` in `sm-sync.config.json`.

A copy that sits inside a git checkout never updates itself. That is the developer copy.

### 3. First upload

Quit Scrap Mechanic, run `Scrap Mechanic Sync.cmd`, press **2**. With nothing in the
bucket yet it offers to upload your copy as the starting point.

### 4. Hand over to the other player

`dev\make-friend-zip.ps1` builds `dist\Scrap Mechanic Sync.zip` from the newest release tag
plus your `sm-sync.config.json`. It refuses to run until every setting, including the
GitHub token, is filled in. The zip holds the keys, so send it privately.

Before sending, `dev\simulate-friend.ps1` unpacks that zip to a temp folder and runs it as
a second player on this PC, with a sandbox save folder and the game launch switched off.
That copy has no `.git`, so it also exercises the real self-update.

## Daily use

Press **1**. The tool downloads the newest world, checks it out to you, starts the game,
waits for you to quit, uploads, and makes the world available again. The window must stay open while you play.

After the upload it asks for an optional note for the next player ("fuel is in the red
chest"). The prompt closes by itself after 60 seconds, and the world is already available
by then.

If the window is closed while the game runs, a hidden helper process uploads the world when
the game exits and shows a Windows notification. If an upload fails, press **2**. The world
stays checked out to you until an upload succeeds.

**W** waits for the other player: it looks once a minute and shows a Windows
notification when the world has been uploaded. It does not check the world out.

The game is started through `steam.exe -applaunch 387990 -open <save file>`, which loads the
shared world and skips the main menu. `"OpenWorldDirectly": false` in the settings file
turns that off and launches to the main menu instead.

The menu takes the up and down arrows plus Enter, or the key in brackets. Options that
cannot be used right now are greyed out with the reason, and **W** and **4** appear only
while the other player has the world. The status box re-checks itself every 30 seconds.

### Playing at the same time

One player presses **1** and hosts. The other does not use the tool: they start the game
from Steam and join through the friends list. Only the host checks out and uploads.

## How the save is protected

- Nobody can play or upload while someone else has the world checked out.
- **Force check-out** overrides that when the other player forgot to finish. Whatever
  they played since their last upload is then out of sync and stays out of the shared world.
- Every download is hash-checked before it replaces the local save.
- The local save is copied to `%LOCALAPPDATA%\SMSync\backups` before every download or
  restore. The last 10 are kept.
- The last 5 uploaded versions stay in the bucket. **Restore a backup** lists local and
  online copies together.
- Nothing is copied while the game is running or holds the file open.
- An upload is refused when the save has a leftover SQLite journal (the game crashed) or
  is not a SQLite file.
- An upload less than half the size of the shared world stops and asks first, in case a new
  world was created under the same name.
- Each upload records Steam's build number for the game. A player whose game is older than
  the save is warned before checking out.
- The menu warns when the game is running without the world checked out to that player.
- After each upload, version files the history no longer points at are deleted from the bucket.
- Network failures are retried three times. A failed upload never releases the check-out.
- The state file is written with a conditional PUT (`If-Match` on its ETag). If two players
  act in the same second, the second write is refused and that player is told to look again.
- Uploads from the menu window and from the background helper are serialised by a named
  mutex, so one session is never uploaded twice at once.

## Storage layout

```
<SaveName>/state.json       holder, heldSince, version, minVersion, history[5], sessions[20]
<SaveName>/v000007.db.gz    one gzip object per version, oldest pruned beyond 5
```

Each history entry holds `version, sha256, size, by, at, gz, stored, note, build`. The hash is of the
uncompressed save. Versions uploaded before 0.2.0 are plain `.db` objects and still restore.
A 32 MB save compresses to about 9 MB.

## Tests

```
dev\test\run-tests.ps1
```

Two players, one on Windows PowerShell 5.1 and one on PowerShell 7, run through check-out,
refusal, upload, download, notes, history pruning, restore, the background helper, forced
check-out, the failure cases and a self-update. Needs python for the fake server. Run it
before tagging a release, because a tag installs itself on the other player's PC.

## Releasing an update

Auto-update follows the highest `vX.Y.Z` tag, never `main`.

1. Change `$script:Version` in `sm-sync.ps1`, and add an entry for that version at the top of
   `CHANGES.txt` in plain words. The other player sees it on a "what is new" screen. The
   tests fail if the entry is missing.
2. Commit, then tag the commit with the same number, for example `v0.2.0`.
3. Push the commit and the tag.

At its next launch, or within 15 minutes if its menu is already open, the other copy downloads that tag, checks that the new script parses
and passes `-Action selftest`, and only then replaces itself and restarts. If either check
fails it keeps running the old version and says so.

`$script:MinPeerVersion` is written into `state.json`. Raise it in a release that changes
the state format, and every older copy refuses to sync until it has updated.

## Troubleshooting

- Log: `%LOCALAPPDATA%\SMSync\sm-sync.log`.
- **D** in the menu runs the same checks as `doctor` below and copies a report to the
  clipboard, for the other player to paste to you. **A** shows the last 20 sessions.
- `sm-sync.ps1 -Action doctor` checks the keys, that the storage honours conditional writes,
  the update token, and that the game can be found.
- `sm-sync.ps1 -Action selftest` checks request signing against Amazon's published example.
- `-Action status|play|finish|take|update` run without the menu. `-Plain` turns colours off.
- Steam Cloud also syncs the save folder per account. On a Cloud conflict, keep the
  local files.

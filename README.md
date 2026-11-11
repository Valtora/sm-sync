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
4. Expiry: one year is the maximum. Note the date, because updates stop when it expires.
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

If the window was closed or the upload failed, press **2** afterwards. The world stays
checked out to you until an upload succeeds.

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
- Network failures are retried three times. A failed upload never releases the check-out.

## Storage layout

```
<SaveName>/state.json     holder, heldSince, version, minVersion, history[5]
<SaveName>/v000007.db     one object per uploaded version, oldest pruned beyond 5
```

## Releasing an update

Auto-update follows the highest `vX.Y.Z` tag, never `main`.

1. Change `$script:Version` in `sm-sync.ps1`.
2. Commit, then tag the commit with the same number, for example `v0.2.0`.
3. Push the commit and the tag.

At its next launch the other copy downloads that tag, checks that the new script parses
and passes `-Action selftest`, and only then replaces itself and restarts. If either check
fails it keeps running the old version and says so.

`$script:MinPeerVersion` is written into `state.json`. Raise it in a release that changes
the state format, and every older copy refuses to sync until it has updated.

## Troubleshooting

- Log: `%LOCALAPPDATA%\SMSync\sm-sync.log`.
- `sm-sync.ps1 -Action selftest` checks request signing against Amazon's published example.
- `-Action status|play|finish|take|update` run without the menu. `-Plain` turns colours off.
- Steam Cloud also syncs the save folder per account. On a Cloud conflict, keep the
  local files.

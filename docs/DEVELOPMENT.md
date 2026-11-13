# Development notes

## Files

| File | Purpose |
| --- | --- |
| `Scrap Mechanic Sync.cmd` | Launcher. Opens the menu in Windows Terminal when installed, otherwise in the classic console. |
| `sm-sync.ps1` | The whole tool. Runs on Windows PowerShell 5.1 and PowerShell 7. Must stay ASCII only. |
| `sm-sync.config.json` | Settings with the storage keys. Written by the setup. Untracked, never commit it. |
| `sm-sync.config.example.json` | Template for writing the settings by hand. |
| `CHANGES.txt` | Plain-language release notes, shown to players after an update. |
| `FRIEND-INSTRUCTIONS.txt` | Everyday guide for players. |
| `dev\make-release-zip.ps1` | Builds the zip attached to a GitHub release. |
| `dev\simulate-friend.ps1` | Runs a release zip as a second player on this PC. |
| `dev\make-screenshots.ps1` | Retakes the screenshots in `docs\` from a demo copy with made-up data. |
| `dev\test\run-tests.ps1` | End-to-end tests against a local stand-in for the storage and for GitHub. |

## How the save is protected

- Nobody can play or upload while someone else has the world checked out.
- Force check-out overrides that. Whatever the other player did since their last upload
  stays out of the shared world.
- Every download is hash-checked before it replaces the local save.
- The local save is copied to `%LOCALAPPDATA%\SMSync\backups` before every download or
  restore. The last 10 are kept.
- The last 5 uploaded versions stay in the bucket.
- Nothing is copied while the game is running or holds the file open.
- An upload is refused when the save has a leftover SQLite journal or is not a SQLite file.
- An upload less than half the size of the shared world stops and asks first.
- Each upload records Steam's build number. A player whose game is older is warned.
- Network failures are retried three times. A failed upload never releases the check-out.
- The state file is written with a conditional PUT (`If-Match` on its ETag). If two
  players act in the same second, the second write is refused.
- Uploads from the menu window and from the background helper are serialised by a named
  mutex.

## Storage layout

```
<SaveName>/state.json       type, owner, ownerSteamId, holder, heldSince, holderSteamId, version, minVersion, history[5], sessions[20]
<SaveName>/v000007.db.gz    one gzip object per version, oldest pruned beyond 5
```

Each history entry holds `version, sha256, size, by, at, gz, stored, note, build, mods`.
The hash is of the uncompressed save. `type` is `Survival`, `Creative` or `Custom`, set by
the first upload. Requests are signed with AWS Signature V4, implemented in the
script. `-Action selftest` checks the signing against Amazon's published examples.

`owner` is the player who uploaded version 1. Only that player is offered "Delete for
everyone". A world uploaded before 0.4.0 has no owner, and any player may delete it.

Deleting a world replaces `state.json` with a marker (`deleted`, `deletedBy`, `deletedAt`,
`minVersion` 0.4.0), written with `If-Match` so a check-out made a moment earlier wins.
The version objects are deleted afterwards. Every other copy reads the marker and tells
its player. A host who later shares a world of the same name clears the marker.

## Settings file

```
{ "Worlds": [ { Endpoint, Bucket, AccessKeyId, SecretAccessKey, SaveName, Type?, SaveFolder? } ],
  "LastWorld": "<SaveName>", "AutoUpdate"?, "BackupsToKeep"?, "OpenWorldDirectly"? }
```

A file from before 0.4.0 held one world at the top level. `Read-Settings` converts it on
first run and moves that world's backups into `backups\<SaveName>`. The rest of the script
reads `$script:Config`, the top-level settings merged with the selected world, so it does
not know about the list. Worlds are identified by save name, which must be unique on a PC
because it is also the file name in the game.

## World types

The game keeps each type in its own folder under `User\User_<SteamId64>\Save`:

| Type | Folder |
| --- | --- |
| Survival | `Save\Survival` |
| Creative | `Save` itself |
| Custom | `Save\Custom` |

A world entry without `Type` is Survival, as every world was before 0.4.0. Without
`SaveFolder` the tool finds the account's `Save` folder (remembered in `savebase.txt`) and
adds the type's folder. `-open <save file>` loads all three types directly.

## Mods

A world's Game table has a `mods` column: a 4-byte big-endian count, then 24 bytes per
mod, an 8-byte Workshop ID (0 for a local mod) followed by 16 bytes the tool ignores.
`Get-WorldModIds` reads it at upload with `winsqlite3.dll`, the SQLite library that ships
with Windows, opened read-only. Names come from `description.json` in the Workshop folder.
A read failure records no mods and never stops an upload.

Before a check-out, every Workshop ID in the current version must have a folder under
`steamapps\workshop\content\387990` in one of the Steam libraries. `dev\test\make_world.py`
writes a world file with a given mods list for the tests.

## Invite codes

`SMSYNC1:<base64url>:<check>`. The middle part is the endpoint, bucket, access key ID,
secret access key, save name and world type joined by newlines. A code without the type
is a Survival world. The check is the first 6 hex digits of
the SHA-256 of those bytes, which catches a code cut short by a chat app. The code is not
encrypted. It is the keys in another form.

## Reports and privacy

`Protect-Text` runs over every line of a diagnostics report before it reaches the clipboard
or an issue URL. It removes the storage keys and host, any hex string of 32 characters or
more, Steam IDs, the user folder in Windows paths, the Windows user and PC names, player
names, and the world and bucket names. Names shorter than 3 characters are left alone,
because replacing them would mangle ordinary words. The local log is not redacted.

Report issue opens `issues/new?template=bug_report.yml` with the `version` and
`diagnostics` fields filled from the query string. A URL opened through the Windows shell
is cut off near 2,000 characters, so the oldest log lines are dropped until it fits. The
full report is copied to the clipboard as well.

## Tests

```
dev\test\run-tests.ps1
dev\test\run-tests.ps1 -ShowAll
```

Players on Windows PowerShell 5.1 and PowerShell 7 run through check-out, refusal, upload,
download, notes, history pruning, restore, the background helper, forced check-out, the
failure cases, the first-run setup as host and as friend with refused entries and Esc, a
second world, the Worlds screen, deleting a world, the redacted report and a self-update. Needs python for the fake server. Nothing touches a real bucket, a real save
or the game.

Environment variables used by the tests: `SMSYNC_HOME`, `SMSYNC_PLAYER`,
`SMSYNC_SAVE_ROOT`, `SMSYNC_GAME_PROCESS`, `SMSYNC_GAME_BUILD`, `SMSYNC_STEAM_ID`,
`SMSYNC_NO_TOAST`, `SMSYNC_NO_CLIPBOARD`, `SMSYNC_NO_LAUNCH`, `SMSYNC_WAIT_SECONDS`,
`SMSYNC_REPORT_FILE`, `SMSYNC_TEST_CHECKOUT_DELAY`, `SMSYNC_FORCE_FANCY`, `SMSYNC_HEIGHT`.
`SMSYNC_KEYS` is a comma-separated list of answers used up before the keyboard is read,
which is how the screenshot script reaches a given screen.

## Releasing

Every copy that is not inside a git checkout follows the highest `vX.Y.Z` tag, never
`main`. A tag therefore installs itself on other people's PCs. Run the tests first.

1. Change `$script:Version` in `sm-sync.ps1` and add an entry for that version at the top
   of `CHANGES.txt`, in plain words. The tests fail if the entry is missing.
2. Commit, tag the commit with the same number, and push both.
3. Build the download and attach it to a GitHub release. The README and the invite
   message link to `releases/latest/download/Scrap-Mechanic-Sync.zip`, so every release
   needs this asset under exactly that name.

```
dev\make-release-zip.ps1
gh release create vX.Y.Z "dist\Scrap-Mechanic-Sync.zip" --title vX.Y.Z --notes-file CHANGES.txt
```

At its next launch, or within 15 minutes if its menu is open, each copy downloads the tag,
checks that the new script parses and passes `-Action selftest`, and only then replaces
`sm-sync.ps1`, `*.cmd` and `*.txt`. If a check fails it keeps the old version and says so.

`$script:MinPeerVersion` is written into `state.json`. Raise it in a release that changes
the state format, and every older copy refuses to sync until it has updated.

Update checks are unauthenticated calls to the GitHub API, limited to 60 an hour per IP
address. One copy makes 4 an hour while its menu is open.

## Command line

`sm-sync.ps1 -Action status|play|finish|take|wait|doctor|update|selftest` run without the
menu, on the world used last or the one named with `-World "<save name>"`. `-Action setup`
adds a world. `-Plain` turns colours off, `-NoUpdate` skips update checks, `-Yes`
answers yes to confirmations. The log is `%LOCALAPPDATA%\SMSync\sm-sync.log`.

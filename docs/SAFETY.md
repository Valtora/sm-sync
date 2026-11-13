# Safety and privacy

## What the tool does on your PC

The tool is one PowerShell script, [sm-sync.ps1](../sm-sync.ps1), and you can read all of
it. It:

- Reads and writes the one save file you chose, and keeps backups in
  `%LOCALAPPDATA%\SMSync`.
- Talks to your storage bucket, and to GitHub to look for updates.
- Starts the game through Steam.
- Replaces its own files when a new release is tagged in this repository.

Nothing is sent to the author. The storage belongs to the person who set it up.

## Things to know before you rely on it

**An invite code is a key.** Anyone who has it can download, replace or delete the shared
world. Send it in a private message, never in a public channel or a screenshot. If one
leaks, delete the API token in Cloudflare, create a new one, run the setup again and send
new invites.

**The settings file holds the same keys.** `sm-sync.config.json`, next to the tool, should
never be posted or shared.

**Windows may warn you** about a script downloaded from the internet. The
[setup guide](SETUP.md#download-and-first-start) explains the two prompts you might see.

**Steam Cloud also syncs the save folder.** If Steam reports a conflict, keep the local
files.

## Automatic updates

Each copy looks for a newer release when it starts and every 15 minutes while its menu is
open. Before installing, it checks that the new script loads and passes its self-test. If
either check fails it keeps the version it has and says so. After an update it shows what
changed.

To turn updates off, add `"AutoUpdate": false` to `sm-sync.config.json`.

## What a report contains

Diagnostics (**D**) and Report issue (**I**) build a report from the tool's checks and the
last 12 lines of its log. Before the report leaves your PC, the tool removes:

- player names
- storage keys and the storage address
- Steam IDs
- your Windows user name and PC name
- the names of your world and your bucket

Names shorter than three characters are left as they are, because replacing them would
garble ordinary words.

Report issue shows you the report first and sends nothing itself. It opens the issue form
in your browser with the report filled in, and you press the button. Issues are public, so
read the report through before you submit it.

The log file on your own PC, `%LOCALAPPDATA%\SMSync\sm-sync.log`, is not redacted. Do not
attach it to an issue.

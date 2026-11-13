# Scrap Mechanic Sync

Share one Scrap Mechanic Survival world between friends without a dedicated server and
without sending save files to each other.

The world is kept in online storage. It works like a library book: one player checks it
out, the game opens straight into it, and when they quit the tool uploads their progress
for the next player. If a friend is already playing, press **J** to join their game.

<!-- Screenshot of the main menu goes here: ![The main menu](docs/menu.png) -->

- **One file to double-click.** A text menu in a terminal window. Nothing to install: it
  runs on the PowerShell that ships with Windows.
- **Two copies never go out of sync.** Only the player who has the world checked out can
  play and upload. Two players pressing Play in the same second are caught.
- **Backups at every step.** The last 5 uploads stay online and the last 10 local copies
  stay on each PC. Any of them can be restored from the menu.
- **Notes between players.** Leave a message after your session, such as "fuel is in the
  red chest".
- **Updates itself** from this repository, and shows what changed.

## What you need

- Windows 10 or 11, and Scrap Mechanic on Steam.
- **One person in the group** needs a Cloudflare account for the storage (R2). Cloudflare
  asks for a payment card when R2 is switched on. A shared world uses a few megabytes of
  the 10 GB free allowance, so normal use costs nothing.
- Everyone else needs only an invite code from that person.

## Getting started

**Download:** [Scrap-Mechanic-Sync.zip](https://github.com/Valtora/sm-sync/releases/latest/download/Scrap-Mechanic-Sync.zip).
Right-click the zip, choose **Extract All**, open the folder and double-click
**Scrap Mechanic Sync**.

The first run is a setup with two routes:

| You are | Choose | What happens |
| --- | --- | --- |
| Starting a shared world for your group | **2** Set up a new shared world | Pick the world, create the storage with on-screen steps, upload, and get an invite to send. About 10 minutes. |
| Joining a friend's world | **1** I have an invite code | Copy the message your friend sent. The tool reads the code from your clipboard. |

[docs/SETUP.md](docs/SETUP.md) has the full walkthrough, including every Cloudflare step
and what to do when the connection test fails.
[FRIEND-INSTRUCTIONS.txt](FRIEND-INSTRUCTIONS.txt) is a plain-text guide to everyday use
that you can send to a friend.

## Everyday use

1. Start the tool, not the game. A desktop shortcut is offered on the first run.
2. The status box says who has the world. If it says **AVAILABLE**, press **1**.
3. The game opens in the shared world. Leave the tool's window open.
4. Quit the game when you are done. The tool uploads and asks for an optional note.

| Key | Does |
| --- | --- |
| **1** | Play: download the newest world, check it out, start the game, upload on quit |
| **2** | Finish session: upload now, for example after a failed upload |
| **3** | Restore a backup, local or online |
| **J** | Join the friend who has the world, as a guest in their game |
| **W** | Wait: a Windows notification tells you when the world is available |
| **4** | Force check-out, for when a friend forgot to finish |
| **A** | Activity: who played when, and their notes |
| **F** | Invite a friend |
| **D** | Diagnostics: check the setup and copy a report |
| **I** | Report an issue here on GitHub, with the report filled in |
| **H** | Help |

## Is it safe?

It is one PowerShell script, [sm-sync.ps1](sm-sync.ps1), and you can read all of it. What
it does on your PC:

- Reads and writes the one save file you chose, and keeps backups in
  `%LOCALAPPDATA%\SMSync`.
- Talks to your storage bucket, and to GitHub to look for updates.
- Starts the game through Steam.
- Replaces its own files when a new release is tagged here. Set `"AutoUpdate": false` in
  `sm-sync.config.json` to turn that off.

Things to know before you rely on it:

- **An invite code is a key.** Anyone who has it can download, replace or delete the
  shared world. Send it privately. If one leaks, delete the API token in Cloudflare,
  create a new one and send new invites.
- **Windows may warn you** about a script downloaded from the internet. The setup guide
  explains the two prompts you might see.
- **Steam Cloud** also syncs the save folder. If Steam reports a conflict, keep the local
  files.
- **Your storage, your data.** Nothing is sent to the author. The storage belongs to the
  person who set it up.

### Privacy when reporting problems

Diagnostics (**D**) and Report issue (**I**) build a report from the tool's checks and the
last lines of its log. Before it leaves your PC, the tool removes player names, storage
keys and addresses, Steam IDs, your Windows user name, and the names of your world and
bucket. Report issue shows you the report and sends nothing itself: it opens the issue
form in your browser and you press the button.

## Help and feedback

- Press **I** in the menu, or open an [issue](https://github.com/Valtora/sm-sync/issues/new/choose).
- Never post an invite code or your `sm-sync.config.json` in an issue.
- Support for other games is not planned.

## For developers

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers the storage layout, the test suite and
how releases work.

## Credits

Written by [Valtora](https://github.com/Valtora).
<!-- Add once he has agreed to be named:
The idea came from a Reddit thread in which u/Gloryboy811 described a similar tool of their own.
-->

Released under the [MIT licence](LICENSE). This project is not affiliated with or endorsed
by Axolot Games. Scrap Mechanic is a trademark of its owner.

---

If this saved you some hassle, you can [buy me a coffee](https://ko-fi.com/valtora).

# Setup guide

There are two routes. One person in each group is the **host**: they create the storage
and invite the others. Everyone else is a **friend** and needs only an invite code.

- [Download and first start](#download-and-first-start) (everyone)
- [Host: set up a new shared world](#host-set-up-a-new-shared-world)
- [Friend: join with an invite code](#friend-join-with-an-invite-code)
- [When the connection test fails](#when-the-connection-test-fails)
- [Changing things later](#changing-things-later)

## Download and first start

1. Download [Scrap-Mechanic-Sync.zip](https://github.com/Valtora/sm-sync/releases/latest/download/Scrap-Mechanic-Sync.zip).
2. Right-click the zip and choose **Extract All**. Put the folder somewhere permanent,
   such as Documents. Keep the files together.
3. Open the folder and double-click **Scrap Mechanic Sync**.

Windows may show one of two warnings, because the file came from the internet:

- A blue box, "Windows protected your PC": click **More info**, then **Run anyway**.
- "Open File - Security Warning": click **Run**.

A black and orange window opens. If Windows Terminal is installed the tool uses it,
otherwise it uses the classic console. Both work.

## Host: set up a new shared world

You need a Survival world that already exists on your PC, and about 10 minutes. Press
**2** on the welcome screen. The tool shows these same steps as you go.

### Step 1: pick the world

The tool lists the Survival worlds on your PC, most recently played first. Type the number
of the one to share. Your other worlds are never touched.

If the list is empty, start Scrap Mechanic, create a Survival world, quit the game and
press **R**.

### Step 2: create the storage

The world lives in Cloudflare R2. The tool can open the right page for you with **O**.

1. Sign in at [dash.cloudflare.com](https://dash.cloudflare.com), or create a free account.
2. In the left-hand menu open **R2 Object Storage**. The first time, Cloudflare asks for a
   payment card to switch R2 on. The free allowance is 10 GB of storage each month. A
   world is a few megabytes and the tool keeps 5 versions, so you stay far below it.
3. Press **Create bucket**. Name it `scrap-mechanic` (any name works), leave the other
   settings alone, and create it.
4. Back in the tool, press **C** and type the bucket name, or press Enter if you used
   `scrap-mechanic`.

### Step 3: create the keys

The keys let the tool read and write that one bucket and nothing else in your account.

1. On the R2 page find **API Tokens** and press **Manage**, then **Create Account API
   token**. (**O** in the tool opens this page.)
2. Permission: **Object Read & Write**.
3. Under **Specify bucket(s)** choose **Apply to specific buckets only** and tick your
   bucket.
4. Leave the expiry as it is, or set one if you prefer. When a token expires, everyone's
   copy stops syncing until you create a new token and send new invites.
5. Press **Create**. Cloudflare shows the values **once**. Keep the page open.
6. In the tool press **C** and paste three values, each followed by Enter:

| The tool asks for | On the Cloudflare page |
| --- | --- |
| The S3 address | Under "Use jurisdiction-specific endpoints for S3 clients", starting with `https://` and ending in `r2.cloudflarestorage.com` |
| Access Key ID | "Access Key ID", 32 characters |
| Secret Access Key | "Secret Access Key", 64 characters. The tool shows stars as you paste. |

Paste with Ctrl+V or a right-click. You do not need the value labelled "Token value".

### Step 4: test

The tool connects, writes a small test object and deletes it. Green lines mean the keys
work. If anything is red, see [When the connection test fails](#when-the-connection-test-fails).

The settings are saved in `sm-sync.config.json` next to the tool. That file holds the
keys. Treat it like a password and never post it.

### Step 5: upload and invite

1. Type your name. Your friends see it when you have the world.
2. Confirm the upload of your world as the starting point. Scrap Mechanic must be closed.
3. The tool shows an **invite code** and copies a ready-made message containing the
   download link, the steps and the code. Paste it into a private message to each friend.

**The invite code is the key to the world.** Anyone who has it can download, replace or
delete the shared world. Do not post it in a public channel and do not share a screenshot
of it. Press **F** in the menu to show it again.

## Friend: join with an invite code

1. Download and start the tool as described [above](#download-and-first-start).
2. Copy the whole message your friend sent you.
3. Press **1** on the welcome screen. The tool finds the code in your clipboard. If it
   does not, paste the message when asked and press Enter.
4. Type your name. Use a different name from your friends.
5. Say yes to the desktop shortcut, and from now on start the game with it.

You do not need a Cloudflare account.

## When the connection test fails

| The tool says | Cause | Fix |
| --- | --- | --- |
| The storage rejected the access keys | A value was pasted into the wrong box, or the token is read-only | Press **K** and paste again. Check the token's permission is **Object Read & Write**. |
| The storage has no bucket named ... | The name typed in step 2 differs from the bucket's real name | Press **B** and type the name exactly as Cloudflare shows it. |
| The clock on this PC is wrong | The storage refuses requests whose time is more than a few minutes out | Windows Settings, Time and language, Date and time, **Sync now**. Then press **T**. |
| Could not reach the online storage | No internet, or a wrong S3 address | Check the address ends in `r2.cloudflarestorage.com`. Press **K** to enter it again. |

If you closed the Cloudflare page before copying the values, delete that token in
Cloudflare and create a new one. The secret cannot be shown a second time.

## Changing things later

- **Run the setup again:** delete `sm-sync.config.json` from the tool's folder and start
  the tool. Backups and your player name are kept.
- **Share a different world:** run the setup again as host and pick the other world. Each
  world gets its own folder in the bucket, so the same bucket and keys can be reused.
- **An invite leaked, or someone should lose access:** in Cloudflare, delete the API token
  and create a new one. Run the setup again with the new keys and send new invites.
- **Turn off automatic updates:** add `"AutoUpdate": false` to `sm-sync.config.json`.
- **Edit the settings by hand:** copy `sm-sync.config.example.json` to
  `sm-sync.config.json` and fill it in. Optional settings are `SaveFolder` (the folder
  that holds the world, if the tool cannot find it), `BackupsToKeep` (default 10),
  `OpenWorldDirectly` (`false` starts the game at its main menu) and `AutoUpdate`.

The tool speaks the S3 protocol, so another S3-compatible storage may work. Only
Cloudflare R2 is tested. The setup warns you if the storage does not support the
conditional writes that stop two players checking out at once.

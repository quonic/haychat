# Using the Client

A reference for every screen and control of the HayChat client. Testers who want a gentler
introduction should start with the [tester guide](tester-guide.md). The settings the client keeps
are listed in [client-configuration.md](client-configuration.md), and the server-side rules
behind rooms, admins, names and unread counts in [rooms-and-accounts.md](rooms-and-accounts.md).

The window opens at once; connecting happens in the background.

## First Run and Settings

- **First run.** When the config has no display name or no server, the client shows a setup
  screen asking for a display name (3 to 32 bytes; accented letters and emoji count as 2 to 4),
  a server host, and a port (default `12345`; `host:port` in the host field works too).
  **Connect** saves the config and connects.
- **Settings.** The gear button at the bottom of the server rail opens the same screen later, to
  change the global display name, add servers, and open a server's own settings from the server
  list. Changing the global name reconnects every server that has no name of its own, and each
  server renames your account (see [Display names](rooms-and-accounts.md#display-names)).

### Server Settings

The gear in the selected server's sidebar header (or **Server settings** in the server button's
right-click menu) opens that server's own settings in the main pane; switching rooms, servers or
conversations closes them again. They apply to that server only and are kept in this profile's
`config.json`, so they are not synced between devices.

- **Profile:** a display name for this server only; empty uses the global one. Saving a new one
  renames your account on this server and reconnects only this server. When an admin of the
  server renamed you and locked the name, the section shows that name with "Set by an admin of
  this server" instead of the field.
- **Server:** the label (headers and the rail tooltip) and short label (the rail button, up to 3
  characters; empty fields are filled in from the address), the host and port (a new address
  reconnects only this server and pins its key afresh), the pinned key's fingerprint with
  **Forget key** (two clicks: clears the pin and reconnects, and the next connection pins
  whatever key the server presents; use it only when you know the server was reinstalled), and
  **Remove server** (two clicks).
- **Voice:** every other user of the server, those in voice first, with a volume slider (0 to
  200 %) and **Mute for me**. Only you hear the change, at once, also while in voice; the user
  and the server are not told. A muted user's voice is dropped before it is decoded.
- **Admin** (admins only): the server's accounts and rooms. See [Administration](#administration).

## Connection Status and Reconnecting

- **Status.** The sidebar footer shows the selected server's status ("Connected as alice",
  "Connecting…", "Reconnecting in 4 s"), and a dot on each rail button shows every server's
  status: green connected, amber connecting or waiting, red stopped. While the selected server is
  not connected, a banner above the room explains why, with a **Retry now** button.
- **Reconnecting.** After a lost connection or a failed attempt the client retries after 1 s,
  2 s, 4 s, and so on, capped at 30 s, each shortened by up to 20 % of random jitter so clients
  do not all return at once. Restarting the server therefore reconnects every client without
  user action.

**Failures that stop retrying.** Some causes cannot fix themselves, so the client stops and says
what to do:

- The name belongs to another account (another person, or another device's key) on that server:
  choose another name in Settings, or one for that server only in its Server settings (**Open
  settings** in the banner goes to the one the server uses).
- The server's identity key does not match the pinned one (expected after a server reset or
  reinstall): **Trust the new key** replaces the pin, saves the config, and reconnects.
- The client and server speak different protocol versions (see [protocol.md](protocol.md)).
- The display name is too short or too long, or the identity key in the config is corrupt.
- An admin kicked or banned the account: the banner says **Kicked** or **Banned** with the
  admin's reason, and **Retry now** connects again (after a kick, or once the ban is lifted).
  Voice is not rejoined by itself afterwards.

## Rooms, Direct Messages and Unread Counts

The selected server's sidebar lists its **Channels**, then **Direct Messages** (recent
conversations, newest first) and **Members** (every other account, online first, then
alphabetical). A green dot marks an account that is online.

- **Rooms.** The channel list shows the rooms you are in: every **Public** room, and the invite
  rooms someone added you to. Clicking a channel opens it, with **Load older messages** at the
  top while older history exists. A voice-only room shows "This room is voice only" where the
  composer would be. In a room whose history is **From join** you see only what was sent after
  you were added. See [Room access](#room-access).

### Room Access

Each room has an access mode, chosen when it is created:

| Mode | Who is in it | Who adds people | Who removes people |
| --- | --- | --- | --- |
| **Public** | Every account, new ones too | Nobody needs to | Admins |
| **Member invite** | Whoever was added | Its members and admins | Admins |
| **Admin invite** | Whoever was added | Admins | Admins |

- **Members…** in a channel's right-click menu (invite rooms, and every room for admins) opens
  the room's **Members** page: who is in it, **Add** next to everyone else when you may add
  people, **Remove** for admins, and **Leave room**.
- **Invite to room…** in an account's right-click menu lists the rooms you may add people to;
  pick one and the answer ("Added bob to #team.") shows under the composer.
- **Leave room…** in a channel's menu leaves an invite room (it takes a second click, "Click
  again to leave"). Public rooms cannot be left. In an Admin invite room only an admin can add
  you back.
- **History for new members** is set when the room is created and never changes: **From join**
  (new members read only what is sent after they were added; someone removed and added again
  starts over) or **Full history** (they read everything). Public rooms always show the whole
  history.
- Unencrypted rooms are readable by the server: access modes decide who the server lets read
  a room, and the server and its operator can still read every unencrypted room.
- **Encrypted rooms** (invite rooms an admin created with **Encrypt this room**, shown with a
  🔒 before the room's name in its header) are end-to-end encrypted: every message is sealed by
  its sender's client for the members the room's signed member list names, the server stores
  only sealed bytes, and each opened message carries a 🔒. Your first message in a session
  (and the first after the member list changed) waits a moment under "Setting up
  encryption…" while your client hands its new room key to the members. A message whose key
  has not reached you yet shows **Waiting for this message's key from <name>**: your client
  asks the sender, whose client answers when it is online and you were a member when the
  message was sent; it opens by itself once the key arrives. A message that fails its checks
  shows **This message could not be decrypted** and stays that way. Someone removed from the
  room keeps what they could already read but gets no key for anything sent after the
  removal; someone added to a From join room reads what is sent from then on. In a **Full
  history** encrypted room a newcomer reads the older messages too: the member who added them
  hands over the keys they hold, and other members' clients answer for the rest, so an older
  message opens once a member who has its key is online (until then it shows **Waiting for
  this message's key**). Losing your key store file does not lose the room's
  messages: your client fetches the keys again from the server. Voice in an encrypted room is
  end-to-end encrypted too ([Encrypted voice](#encrypted-voice)). Their **Members** page lists
  the
  members, the **managers** (who sign who joins, add and remove people and other managers)
  and the server's **admins** separately, each with their key state ("Verified", "Not
  verified", "Key changed", "No key"). A manager can **Make manager** / **Remove manager**, and
  a manager who is also an admin can switch the room between letting members invite and
  letting only admins invite. An admin who is not a manager can still remove people (the
  server records it) but is told "Only this room's managers can add members; ask <names>".
  Every change shows in the room as a line from **Member list** ("alice added carol", "the
  server removed dave"). If the server ever presents a member list that does not match what
  your client verified, the room says **This room's member list was changed on the server**
  and your client changes nothing more in it; tell an admin.
- **Direct messages.** Clicking a conversation or a member opens the conversation in the main
  pane, with the person's name and online state in the header, the transcript (your own messages
  are labelled "You"), **Load older messages**, and a composer like the room one. A message that
  arrives for a conversation moves it to the top of **Direct Messages**. Conversations belong to
  one server; the rail has no separate direct-message button.
- **Unread counts.** A channel or conversation with unread messages is drawn bold with a count
  badge ("99+" from 100 on). The client marks the conversation you are looking at (selected, with
  the window focused) read up to its newest loaded message, and reading on one device clears the
  badge on your other devices. The exact rules are in
  [rooms-and-accounts.md](rooms-and-accounts.md#unread-counts).

## Context Menus

Right-click opens a menu at the pointer, kept inside the window. Up and Down move through it,
Enter picks, and Esc or a click outside closes it (that click does nothing else).

| Where | Entries |
| --- | --- |
| Channel | Mark as read (when it has unread messages, including ones not loaded yet), Join voice or Leave voice (not in a text-only room), Copy room name, Members… (invite rooms; every room for admins), Leave room… (invite rooms; "Click again to leave", then you leave); admins also get Edit room… and Delete room… (the room form opens with **Confirm delete** armed, so one more click deletes) |
| Direct Messages and Members rows, sender names above messages | Send message, Mark as read (for an existing conversation with unread messages), Copy name, Verify encryption… (for someone else, see [Encryption keys](#encryption-keys)), Invite to room… (for someone else, when you may add people to a room: it lists those rooms) |
| Voice participant in the channel list | Send message and Copy name, Invite to room… (as above), and for anyone but you **Mute for me** / **Unmute for me** and a volume slider (0 to 200 %, kept like the Voice section of Server settings) |
| Message | Copy message, Copy selected text (with a selection in the transcript), Copy name, Quote (adds the message as `> ` lines to your draft and focuses the composer), and in rooms Send message to sender for other people's messages |
| Server button in the rail | Server settings, Retry now (while not connected), Copy address, Remove server… (the entry turns into "Click again to remove"; the second click removes it) |
| Text fields (the composer and the Settings fields) | Cut, Copy, Paste, Select all |

Admins also get **Rename…**, **Make admin** or **Remove admin**, **Kick…**, and **Ban…** or
**Unban** on account rows, voice participants and sender names, greyed out where the server
refuses them. **Rename…**, **Kick…** and **Ban…** open Server settings → Admin with that
account's confirmation open, since they need a name or a reason.

## Voice

Every room carries voice unless an admin made it text-only, and the client is in at most one
room's voice at a time. It sends the microphone encoded with Opus and plays every other
participant. **Mute** stops sending at once, **Deafen** stops playback at once, and after a
reconnect the client joins the same room's voice again by itself.

An account has one voice session: joining voice on a second device moves you there, and the
first device leaves voice with "joined voice on another device". The automatic re-join after a
reconnect never moves voice away from another device: while another device of yours is in voice
it is refused with "voice is active on another device", and that device stays in voice.

Voice needs libopus (see [Client Dependencies](development.md#client-dependencies)); without it,
or without a working audio device, voice reports why and chat keeps working. There is no echo
cancellation or noise suppression: use headphones.

- **Room header:** **Join voice**, or **Leave voice** while in (or joining, or re-joining) that
  room's voice. A text-only room has no **Join voice**.
- **Channel list:** a room with anyone in its voice shows a speaker and a count, and lists the
  participants under it, also for rooms you are not in. Each user is listed once; a dot ringed
  green means they are speaking (known for the room you are in), and "muted" or "deafened"
  follows the name.
- **Voice bar** (bottom of the sidebar): "Voice connected: #room on Server" with your own
  speaking dot, an input level meter, and **Mute**, **Deafen** and **Leave**; "Joining voice…"
  and "Rejoining voice…" while on the way; the error ("Voice unavailable: libopus not found",
  "Microphone not available: …", or the server's refusal) with **Dismiss** when voice failed.
- **Per-user volume and mute:** Server settings → Voice, or a voice participant's right-click
  menu. Only you hear the change.

### Encrypted voice

Voice in an encrypted room (🔒 before its name) is end-to-end encrypted: the server relays it
but cannot listen. The voice bar shows "🔒 Voice is end-to-end encrypted" there. Voice in an
unencrypted room is not: the server can hear it as it relays it.

- **Joining** needs the room's verified member list and a valid encryption key on this profile.
  Until then **Join voice** reports why: "Setting up encryption…" (the member list is still
  loading; try again in a moment), "This profile has no valid encryption key", or "This room's
  member list was changed on the server".
- **Who can listen.** Your client hands its voice key only to the members the room's verified
  member list names, and makes a new one whenever someone is added or removed, every 30
  minutes, and when you change audio device. Someone removed from the room is taken out of its
  voice and gets no key for anything said after the change.
- **Waiting for a key.** A participant whose key has not reached you yet shows "no key" after
  their name and **Waiting for <name>'s voice key** when you hover it; your client asks for it
  after two seconds. You hear them as soon as it arrives.
- **Keep your clock synchronised.** A voice key carries the time it was made, and clients
  refuse keys made more than an hour ago or more than five minutes in the future, so a
  recording cannot be played back later as live audio. If your computer's clock is off by more
  than about half an hour, others cannot hear you in encrypted rooms (and you may not hear
  them); a participant whose key was refused for its time shows "clock" and **Clock out of
  sync**. Turn on automatic time synchronisation in your operating system.
- **What stays visible.** The server still sees who is in voice, who talks and when, and for
  how long. Encrypted rooms send audio at a constant bitrate, so the size of the voice packets
  does not give away what is said.

### Settings → Voice

- Input and output device lists ("System default" first; a chosen device that is unplugged stays
  listed as "(not connected)", and the default plays meanwhile).
- Voice activity or push-to-talk, and the push-to-talk key (click it, press a key; Esc cancels).
- The voice activity threshold over a live input level meter, input gain, output volume, and the
  Opus bitrate.
- **Test microphone** runs a loopback (microphone → Opus → your own speakers) while the section
  is open and you are not in voice.

Every change applies at once: levels, mode and bitrate to the running voice session in place, a
new device by reopening the audio devices while the session stays joined (listeners do not drop
what follows). Devices are listed only while the section is open, and refreshed on hotplug; a
session on a named device that is unplugged reopens on the system default, and returns to the
named device when it is plugged back in.

### Push-to-talk

Push-to-talk reads the key from the HayChat window while it has focus, and, with **In other
windows too** on (the default, `voice_ptt_global`), while another window has focus as well. A key
that types (a letter, digit, punctuation, Space, Enter, Tab, Backspace, Delete or Esc) is ignored
while a HayChat text field has keyboard focus, so it types there instead of opening the
microphone. In other windows it does open the microphone while you type, so modifiers such as
the default Left Ctrl, and F-keys, suit push-to-talk best.

In other windows, push-to-talk works per platform (`client/hotkey`). The key is followed only
while you are in voice (or joining it) or testing the microphone; nothing is read or set up
before that.

- **Windows:** `GetAsyncKeyState` reads the one configured key; no keyboard hook is installed.
- **Linux on X11:** `XQueryKeymap` reads the one configured key (libX11 is loaded at runtime).
- **Linux on Wayland:** the desktop's GlobalShortcuts portal (KDE Plasma, GNOME 48 and later,
  Hyprland), over libdbus-1 loaded at runtime. The desktop owns the shortcut: the first time you
  use push-to-talk in voice it asks you to confirm the key HayChat proposes (a modifier alone,
  such as Left Ctrl, is not proposed, so you choose one), and Settings → Voice shows the shortcut
  it assigned, with **Change shortcut** where the portal supports it. Inside the window the
  configured key works as well.
- Where none of these is available (a Wayland desktop without the portal, or an unmapped key),
  Settings → Voice says why, and push-to-talk works while the window has focus.

## Encryption Keys

Direct messages are end-to-end encrypted whenever both people can receive encrypted messages
(see [Encrypted direct messages](#encrypted-direct-messages)); room chat is not yet, and the
server can still read it (see [protocol.md](protocol.md)). This section is about the keys that
make that work: each profile's encryption key and the way you check other people's keys, so
encrypted messages reach only the people you mean.

- **Your key.** The client makes an encryption key on first start, keeps it in `config.json`
  next to your identity key, and gives it to every server you sign in to. You do nothing.
- **Other people's keys.** The first time the client sees someone's key on a server (for
  example when you open a conversation or their **Verify encryption…**), it remembers it
  ("pins" it) in that server's [key store](client-configuration.md#key-store). The Members and
  Direct Messages rows show what the client knows: **unverified** (pinned, not compared yet),
  **verified**, **key changed**, or **key problem** (the server sent no key or a bad one for
  someone it had one for). Hover a row for the full sentence.
- **Verify encryption….** Right-click someone in Members or Direct Messages and pick **Verify
  encryption…**. The dialog shows a safety number of 60 digits. Compare it with the number the
  other person sees for you, in person or over a call you trust: it is the same on both sides,
  and on every server where you both have an account. If it matches, click **Mark as verified**.
  If it does not, do not mark it: someone in between is showing you a different key.
- **"<name>'s key changed".** Accounts never change keys, so a different key means the server
  (or whoever controls it) may be trying to read your messages, or its database was replaced.
  The conversation shows a warning with **Verify** and **Trust the new key**, and encrypted
  messages to that person will be blocked until you choose. Verify first: ask them, and compare
  the new safety number. **Trust the new key** pins it without comparing.
- **"<name> set up encryption again".** That person's client made a new encryption key, which
  happens when its `config.json` lost the old one. It is signed by the same identity key, so the
  client accepts it, but it is no longer marked verified: compare the safety number again.
- **Losing `config.json`.** Your encryption key exists only in your `config.json`, next to your
  identity key. If you lose the file you get a new identity, which every server treats as a new
  account, and you will not be able to read your encrypted messages again: not the ones you
  received, and not the ones you sent. Keep a copy of the file somewhere safe (it is a secret:
  never share it). Losing a key store file only means each person is pinned again on first
  contact; your encrypted messages open again from the server's copies, because they are
  sealed to the key in `config.json`.

### Encrypted Direct Messages

- **When it happens.** A direct message is encrypted whenever the client has a key for the
  other person that it trusts (pinned, not changed). You do nothing. The conversation's header
  says "🔒 End-to-end encrypted", and each encrypted message carries a 🔒. The server stores
  and forwards it without being able to read it; it still sees who wrote to whom and when.
- **"Setting up encryption…".** The first time you write to someone the client fetches their
  key. A message you send meanwhile waits and goes out as soon as the key is there.
- **When encryption is not possible.** If the other person has not set up encryption yet (they
  have not signed in since their server was updated), their key changed, or the server stops
  providing a key it gave before, the composer is replaced by a banner saying why. Once a
  conversation was encrypted, it is never quietly sent without encryption again.
- **Send without encryption.** The banner has a **Send without encryption** switch, off by
  default, for when you must reach the person anyway (for example to ask them to update their
  client). The first time you turn it on in a conversation, HayChat asks you to confirm that the
  server and its operator can read these messages. While it is on, the composer says
  "Unencrypted: the server can read this" in red and the button reads **Send unencrypted**. It
  turns itself off when you close the conversation, when you restart HayChat, and as soon as
  encryption works again. Messages sent this way are still signed, so nobody can change them
  or send them in your name.
- **Badges.** Each message shows how it was sent: 🔒 (encrypted); **Unencrypted** (sent with the
  switch: the server could read it); **Unencrypted, sender not verified** (unencrypted, and its
  signature does not match the sender's key: treat it as possibly forged); **Not encrypted**
  (sent before encryption existed on this server). A conversation whose newest message is
  unencrypted shows **unencrypted** in the Direct Messages list.
- **"This message could not be decrypted".** The message could not be opened with the keys your
  client trusts: it was changed, sealed for someone else, sent under another key, or repeated by
  the server. The client never tries it again with other keys. "Opening encrypted message…"
  means the client is still fetching the sender's key.

## Administration

Admins are accounts holding the server's `admin` role; how to get the first one is in
[deploy/README.md "First-Time Setup"](../deploy/README.md#first-time-setup). Every other account
sees none of these controls, and the server checks the role for every request. The rules the
server enforces are in [rooms-and-accounts.md](rooms-and-accounts.md#admin-actions).

### Rooms

In the selected server's sidebar, the **Channels** header shows **+ New room**, which opens a
form in the main pane: a name of 1 to 64 bytes (a leading `#` is dropped), an optional
description of up to 256 bytes, a **Type** selector (**Text**, **Voice**, **Text and voice**),
**Who can join** (**Public**, **Member invite**, **Admin invite**; see
[Room access](#room-access)), **History for new members** (**From join** or **Full history**;
fixed for Public rooms, which show everything), and **Join this room** (on by default; Public
rooms always include you), **Encrypt this room** for invite rooms (checked by default; it can
never be turned off later) with its **Managers** (every admin your client sees, checked, you
always; an admin whose key your client could not pin yet cannot be checked), with **Create** or
**Cancel**. An encrypted room opens its **Members** page after it is created and adds you from
its signed member list when **Join this room** is on. The room's members refresh their room
list (every account for a Public room, only you for an invite room), and the admin's client
selects the new room. With **Join this room** off, you are not a member: the room is not in your
channel list and you do not see its messages, but its **Members** page opens at once so you can
add people, and it stays manageable from Server settings → Admin.

A room's header shows **Edit room**, which opens the same form filled in, with **Save**,
**Cancel**, **Members…**, and **Delete room**; delete asks for a second click (**Confirm
delete**) and removes the room with its history. **Who can join** can change between any two
modes: making a room Public adds every account (the form says so), and making a Public room
invite-only keeps everyone in it. An encrypted room's access changes only from its Members page
(a manager who is an admin signs it). Its history setting is shown but cannot change. The form warns before a save that would remove people from a room's
voice, and before deleting `#general` (the server recreates it only on a start with no rooms
left). It closes when another admin renames or deletes its room, and shows the server's answer
when it refuses (for example a duplicate name, or "Admin permission required" when the role was
revoked). Clients whose selected room was deleted move to `#general`, or to the first room when
`#general` is gone.

### Server Settings → Admin

Open it from the sidebar header's gear or the server button's menu. It lists every account of
the server, you included, with an online dot, **Admin** and **Banned** badges, and **Rename…**,
**Make admin** / **Remove admin**, **Kick…** and **Ban…** / **Unban**.

- What the server would refuse is greyed out, and its tooltip says why: kicking, banning or
  removing the role of yourself, kicking or banning another admin (remove their role first), and
  making a banned account an admin.
- **Rename…**, **Kick…** and **Ban…** open a short confirmation under the account: a new name
  with **Lock name** (on by default; an empty name with the lock off unlocks the name the account
  has), or an optional reason the person is shown.
- **Make admin**, **Remove admin** and **Unban** act at once.
- The server's answer, or its refusal, is shown under the account it concerns.

Below the accounts, every room on the server is listed, also those you are not in (greyed, "not
joined"), with its type, access mode and member count, **Members…**, **Edit…**, **Delete…** and
**Create room…**.

A kicked or banned client says so in its banner, with the admin's reason, and neither reconnects
nor rejoins voice by itself.

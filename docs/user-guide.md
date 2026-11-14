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

- **Rooms.** Every account is in every room. Clicking a channel opens it, with **Load older
  messages** at the top while older history exists. A voice-only room shows "This room is voice
  only" where the composer would be.
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
| Channel | Mark as read (when it has unread messages, including ones not loaded yet), Join voice or Leave voice (not in a text-only room), Copy room name; admins also get Edit room… and Delete room… (the room form opens with **Confirm delete** armed, so one more click deletes) |
| Direct Messages and Members rows, sender names above messages | Send message, Mark as read (for an existing conversation with unread messages), Copy name |
| Voice participant in the channel list | Send message and Copy name, and for anyone but you **Mute for me** / **Unmute for me** and a volume slider (0 to 200 %, kept like the Voice section of Server settings) |
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

## Administration

Admins are accounts holding the server's `admin` role; how to get the first one is in
[deploy/README.md "First-Time Setup"](../deploy/README.md#first-time-setup). Every other account
sees none of these controls, and the server checks the role for every request. The rules the
server enforces are in [rooms-and-accounts.md](rooms-and-accounts.md#admin-actions).

### Rooms

In the selected server's sidebar, the **Channels** header shows **+ New room**, which opens a
form in the main pane: a name of 1 to 64 bytes (a leading `#` is dropped), an optional
description of up to 256 bytes, and a **Type** selector (**Text**, **Voice**, **Text and
voice**), with **Create** or **Cancel**. Every connected client refreshes its room list, and the
admin's client selects the new room.

A room's header shows **Edit room**, which opens the same form filled in, with **Save**,
**Cancel**, and **Delete room**; delete asks for a second click (**Confirm delete**) and removes
the room with its history. The form warns before a save that would remove people from a room's
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

Below the accounts, every room is listed with its type, **Edit…**, **Delete…** and **Create
room…**.

A kicked or banned client says so in its banner, with the admin's reason, and neither reconnects
nor rejoins voice by itself.

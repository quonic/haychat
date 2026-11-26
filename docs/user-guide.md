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
  **Connect** saves the config and connects. Tick **I have an invite code** when you were given
  a code: the server then shows its sign-up screen even if anyone may sign up there (see
  [Signing up](#signing-up)).
- **Settings.** The gear button at the bottom of the server rail opens the same screen later, to
  change the global display name, add servers (with the same **I have an invite code**
  choice), and open a server's own settings from the server list. Changing the global name
  reconnects every server that has no name of its own, and each server renames your account (see [Display names](rooms-and-accounts.md#display-names)).

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
- **Signing up:** **Use an invite code** asks this server for its sign-up screen on the next
  connection even if anyone may sign up there. It changes nothing once you have an account.
- **Admin** (admins, and accounts whose roles allow managing rooms, invites or sign-ups): see
  [Administration](#administration).

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
- A sign-up was declined, or is waiting for approval (see [Signing up](#signing-up)).

## Signing Up

A server that is not open to everyone (or one you asked for its sign-up screen, with **I have an
invite code**, **Use an invite code** or an invite link) shows **Sign up on SERVER** in place of
the room, instead of signing you in. The rules behind it are in
[rooms-and-accounts.md](rooms-and-accounts.md#registration).

- **Invite code:** type or **Paste** the code you were given; dashes, spaces and case do not
  matter. The code goes only to this server, encrypted, and the client never saves it. On a
  server where anyone may sign up the code is optional.
- **Why you are signing up:** on a server where a person approves sign-ups, a few words about
  who you are (up to 500 characters), shown to the people who approve. A code made to skip
  approval needs none; the server says so when one is needed.
- **Sign up** sends it. The screen says the name your account will get; change it in Server
  settings first if you want another. A code that is not valid ("This invite code is not valid",
  also for an expired, revoked or used-up one) stays in the field so you can fix it.
- **Waiting for approval:** the request waits until someone approves it. Keep the client open
  and you are signed in as soon as it is approved; otherwise **Check again** later.
- **Sign-up declined:** shown with the reason, if one was given, like a ban: the client does not
  try again until you press **Start again**.
- An account made with a room code is **restricted** to that room: you see only the people you
  share a room with (and the server's admins), and can message only them.

### Invite Links

An invite link (`haychat://HOST:PORT/invite/CODE?key=…`) holds the server's address, the code
and the server's identity key. Opening one (HayChat registers itself as the handler for
`haychat://` links when it starts; see
[client configuration](client-configuration.md#haychat-links)) hands it to the running window,
or starts HayChat, which asks first: **Sign up on SERVER with an invite?** with the server key's fingerprint, **Continue** and **Cancel**. Continue adds the
server if it is new, pins the link's key, switches to it and opens the sign-up screen with the
code filled in; you still press **Sign up**. A link that names another key than the one already
pinned for that address is refused, because it may not lead to the real server. A link for a
server where you already have an account only says so.

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
| **Roles** | Whoever holds one of the room's chosen roles | Nobody: an admin gives the role | Nobody: an admin takes the role away |

- **Members…** in a channel's right-click menu (invite rooms, and every room for admins) opens
  the room's **Members** page: who is in it, **Add** next to everyone else when you may add
  people, **Remove** for admins, and **Leave room**.
- **Invite to room…** in an account's right-click menu lists the rooms you may add people to;
  pick one and the answer ("Added bob to #team.") shows under the composer.
- **Leave room…** in a channel's menu leaves an invite room (it takes a second click, "Click
  again to leave"). Public rooms cannot be left. In an Admin invite room only an admin can add
  you back.
- **Roles** rooms take their members from roles: an admin picks one or more roles when creating
  or editing the room, and everyone holding one of them is a member at once. Being given such a
  role adds you to the room, and losing it (or the role being deleted) takes you out; you cannot
  leave a Roles room yourself. Encrypted rooms cannot be Roles rooms.
- **Room permissions.** A room may let members do less than usual: a room whose members may not
  send shows **You cannot send messages in this room** where the composer would be, and in voice
  you join and listen but nobody hears you (the voice bar says **You cannot speak in this
  room**). A room can also let some roles manage its members or edit it. The controls follow at
  once when a permission or a role changes. See [Permissions](#room-permissions).
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
| Channel | Mark as read (when it has unread messages, including ones not loaded yet), Join voice or Leave voice (not in a text-only room), Copy room name, Members… (invite rooms; every room for admins), Leave room… (invite rooms; "Click again to leave", then you leave); admins and holders of **Manage rooms** also get Edit room… and Delete room… (the room form opens with **Confirm delete** armed, so one more click deletes) |
| Direct Messages and Members rows, sender names above messages | Send message, Mark as read (for an existing conversation with unread messages), Copy name, Verify encryption… (for someone else, see [Encryption keys](#encryption-keys)), Invite to room… (for someone else, when you may add people to a room: it lists those rooms) |
| Voice participant in the channel list | Send message and Copy name, Invite to room… (as above), and for anyone but you **Mute for me** / **Unmute for me** and a volume slider (0 to 200 %, kept like the Voice section of Server settings) |
| Message | Copy message, Copy selected text (with a selection in the transcript), Copy name, Quote (adds the message as `> ` lines to your draft and focuses the composer; both use the latest version of an edited message), and in rooms Send message to sender for other people's messages; for your own messages **Edit message** and **Delete message…**, and for admins **Delete message…** on other people's room messages (see [Editing and deleting messages](#editing-and-deleting-messages)). A deleted message offers only Copy name |
| Server button in the rail | Server settings, Retry now (while not connected), Copy address, Remove server… (the entry turns into "Click again to remove"; the second click removes it) |
| Text fields (the composer and the Settings fields) | Cut, Copy, Paste, Select all |

Account rows, voice participants and sender names also show the account's roles ("Roles: …",
greyed) to everyone. Admins also get **Rename…**, **Make admin** or **Remove admin**, **Kick…**,
**Ban…** or **Unban**, and, once the server has a role to give, **Roles…** (Server settings →
Admin with that account's role checkboxes open), greyed out where the server refuses them. **Rename…**, **Kick…** and **Ban…** open Server settings → Admin with that
account's confirmation open, since they need a name or a reason.

## Editing and Deleting Messages

You can edit and delete your own messages, in rooms and in direct conversations, encrypted or
not. Admins can also delete other people's room messages.

- **Editing.** Right-click your message and pick **Edit message**, or press Up in the empty
  message box to edit your newest message there. The message's text moves into the box under
  an **Editing message** bar: change it and press Enter to save, or press Esc (or the bar's ×)
  to cancel. Whatever you had typed in the box before waits and is back after you save or
  cancel. An edit changes the text only: a message's files stay as they are, and the paperclip
  is hidden while you edit. A message without files cannot be edited to nothing. You can edit
  a message as often as you like, up to 100 times. Editing needs what sending needs: in a room
  where you may not send any more, **Edit message** is greyed out.
- **Encrypted conversations.** An edit of an encrypted message is encrypted too, the same way
  as a new message, and it reaches the people who can read the conversation now. In a
  direct conversation whose encryption is still being set up the bar stays open with "Setting
  up encryption…" and the edit goes out by itself once it can. An encrypted message that could
  not be opened cannot be edited.
- **"(edited)".** An edited message shows its latest version with **(edited)** after it. Rest
  the pointer on it (or click it) for its **Edit history**: the original and each edit, oldest
  first, with the time of each. An edit is shown only once your client has checked that its
  author signed it; one still waiting for a key reads "Waiting for key…", and one that does not
  check out reads "This edit could not be verified" and is never shown: the message keeps its
  last good version and reads **(edited) · An edit could not be verified**. Editing never
  makes a message unread again.
- **Deleting.** **Delete message…** asks first: deleting erases the message's text, its files
  and its edit history from the server for everyone. The message's place stays, as one grey
  line with its sender: **Message deleted**. Deleting does not recall anything: whoever already
  read the message, saved its files or copied it keeps what they have.
- **Deleted by an admin.** Admins can delete any room message (not direct messages, which they
  cannot read) with **Delete message…**; its confirmation says that members will see
  **Removed by the server**. That is also what you see for any deletion your client cannot
  confirm the author made: HayChat cannot tell which admin removed a message, and a server could
  remove one by itself, so it never names anyone. Only a deletion signed by the author reads
  "Message deleted".

## Files

A message in a room or a direct conversation can carry up to four files, with or without text.
HayChat never opens, runs or previews a file: it only saves it where you choose, and you open it
yourself.

- **Attaching.** Click the paperclip at the left of the composer ("Attach files (or drop them
  on the window)") and pick one or more files, or drop files on the window. Each becomes a chip
  above the composer with its name, "N% of SIZE" and a progress bar while it uploads, and a
  remove button ("Remove from the message"). Removing a chip stops its upload; a finished file
  you remove is never sent and the server deletes it later.
- **When the paperclip is greyed out.** Its tooltip says why: you may not send messages or
  attach files in this room ("You cannot attach files in this room", the room's **Attach
  files** permission), the room is voice only, or the message already has four files ("A
  message can carry at most 4 files"). It is hidden while the server has attachments turned off
  or you are not connected.
- **Refused before uploading.** The server tells the client its limits when you sign in. A file
  larger than the server allows ("Attachment is too large"), one that does not fit your storage
  quota ("Attachment storage quota exceeded"), or one HayChat cannot read becomes a red chip with
  the reason, and nothing is uploaded. The server checks every limit again anyway.
- **Sending.** Enter (or the **Send** button at the right of the chips) sends the text and the
  files together; with files the text may be empty. Until every file is uploaded, Send is shut
  and says why under the chips: "Waiting for 1 upload to finish…" (or "Waiting for N uploads to
  finish…"), "Remove the file that could not be uploaded to send" (or "the files"), or, in a
  direct conversation whose **Send without encryption** switch changed after the upload, "A file
  was uploaded unencrypted; remove it and attach it again" (or "encrypted"). The chips go once
  the message is sent.
- **Encryption.** In encrypted rooms and encrypted direct conversations your client encrypts
  each file before it uploads it, and the file's key, name and type travel inside the encrypted
  message: the server stores only ciphertext, padded to a coarse size, and sees how many files a
  message has and who downloads them. **Send without encryption** in a direct conversation
  covers the files as well as the text. In other rooms the server can read the files, as it can
  read the text, but the sender's signature covers each file's contents, name and type, so
  nobody can swap one.
- **Encrypted direct messages being set up.** While HayChat fetches the other person's key
  ("Setting up encryption…") a message with files waits in the draft rather than in the queue;
  send it again once the conversation is encrypted.
- **File cards.** A file in a message is a card with 📄, its name, "SIZE · type" and **Save…**. A
  message with only files shows only its cards. Right-click a card for **Save…**, **Copy file
  name** and, for admins, **Remove attachment…**.
- **Saving.** **Save…** opens your system's save dialog in your Downloads folder with the file's
  name, cleaned up so it is safe on every system: separators, control characters and
  `: * ? " < > |` become `_`, leading dots and trailing dots or spaces go, Windows device names
  (such as `CON` or `COM1`) get a `_` in front, and a name with nothing left is "attachment".
  While it downloads the card says "Saving… N%" with a bar and **Cancel**, then "Saved as NAME".
  HayChat writes to `NAME.part` next to the file and renames it only after checking every byte
  against what the sender signed or sealed.
- **When saving fails.** "This attachment was changed on the server" means the bytes the server
  sent are not the ones the sender sent; nothing is kept. "Attachment unavailable" means the
  server has no such file for you (it answered "Attachment not found"), also when the file is
  gone from the server's disk, for example after a restore that brought back the database
  without the blob directory; the server then usually marks the file removed, and its card
  changes to "Attachment removed by an admin". "Server storage error" means the server has the
  file but could not read it from its disk. "Attachment removed by an
  admin" replaces the card's button when an admin removed the file. "This message's
  attachments were changed on the server" replaces all of a message's cards when the server's
  list of an encrypted message's files is not the one inside it. Other failures (a lost
  connection, a folder you cannot write to) are shown on the card; click **Save…** again.
- **Who can download.** Whoever can read the message: the room's members (in a From join room,
  only files sent after they joined) and the two sides of a direct conversation. Admins get no
  way around that.

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
or without a working audio device, voice reports why and chat keeps working. HayChat cancels
the echo of what it plays when WebRTC audio processing is available (see
[Echo cancellation](#echo-cancellation)), and removes background noise (see
[Noise suppression](#noise-suppression)); headphones still sound best.

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
- **Echo and noise on Linux:** PipeWire can cancel echo and suppress background noise before
  HayChat hears your microphone instead; see [Voice on Linux](voice-linux-audio.md). Use one
  echo canceller, HayChat's or PipeWire's, not both.

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
  how long. Encrypted rooms pad every voice packet to the same size, so the size of the
  voice packets does not give away what is said. This uses somewhat more bandwidth while you
  talk.

### Settings → Voice

- Input and output device lists ("System default" first; a chosen device that is unplugged stays
  listed as "(not connected)", and the default plays meanwhile).
- Voice activity or push-to-talk, and the push-to-talk key (click it, press a key; Esc cancels).
- **Noise suppression** and **Echo cancellation** on or off (see below). While echo
  cancellation is unavailable or off, a note at the top of the section says to use headphones.
- The voice activity threshold over a live input level meter, input gain, output volume, and the
  Opus bitrate.
- **Test microphone** runs a loopback (microphone → Opus → your own speakers) while the section
  is open and you are not in voice.

Every change applies at once: levels, mode and bitrate to the running voice session in place, a
new device by reopening the audio devices while the session stays joined (listeners do not drop
what follows). Devices are listed only while the section is open, and refreshed on hotplug; a
session on a named device that is unplugged reopens on the system default, and returns to the
named device when it is plugged back in.

### Noise suppression

**Noise suppression** (Settings → Voice, `voice_noise_suppression`, on by default) removes
steady background noise such as fans, hum and traffic from your microphone before it is
encoded, mostly between words. RNNoise 0.2 does it, except while
[Echo cancellation](#echo-cancellation) runs: then WebRTC's noise suppressor does it, right
after the echo canceller, because RNNoise behind an echo canceller takes speech away when you
and the others talk at once. Never both: two suppressors in a row take speech away. Turning
echo cancellation on or off (for example for a headset) switches between them at once.
Without RNNoise installed, WebRTC's suppressor does it in every case.
In voice activity mode RNNoise also says whether a frame is speech (with WebRTC's suppressor it
only listens), and only speech that is louder than the threshold opens the microphone, so loud
noise that is not speech does not. The level meter and **Test microphone** show the signal
after noise suppression. RNNoise adds 10 ms of delay and costs about 0.6 % of one CPU core;
WebRTC's suppressor adds none, and removes less noise than RNNoise (about 18 dB of steady
noise, against RNNoise's 60 dB or more), which the speech gate makes up for between words. It
changes nothing in what is sent over the network: it works the same in encrypted and
unencrypted rooms, and listeners need nothing.

- RNNoise 0.2 removes loud typing less well than older versions did; key clicks can still get
  through.
- RNNoise is loaded when it is needed: `librnnoise.so.0` from the distribution on Linux (the
  `rnnoise` package on Fedora and Arch, `librnnoise0` on Debian testing), `rnnoise.dll` next to
  `haychat-client.exe` on Windows (the release zip has it). Without it voice works, the toggle
  reads **Noise suppression: unavailable**, and the note under it says why; the threshold alone
  then decides when you are speaking.

### Echo cancellation

**Echo cancellation** (Settings → Voice, `voice_echo_cancellation`, on by default) removes the
voices HayChat plays from your microphone, so with speakers the others do not hear themselves.
It is WebRTC's echo canceller (AEC3, from webrtc-audio-processing 2), the one web browsers use
for calls. It compares your microphone with what HayChat plays and finds the delay between them
itself, so it works with any speakers and microphone and keeps up when the delay changes; it
needs a few seconds after you join to settle. While it runs, WebRTC's noise suppressor does the
noise suppression too (see above). It adds no delay and costs about 0.5 % of one CPU core
(about 100 µs per 20 ms; 200 µs with noise suppression). Nothing on the network changes.

- It only removes what HayChat itself plays. Music or a video from another app still reaches
  your microphone; headphones avoid all of it.
- With headphones you do not need it: turn it off to save the CPU.
- Use one echo canceller. If you set up PipeWire's echo cancellation on Linux
  ([Voice on Linux](voice-linux-audio.md)), turn HayChat's off.
- On Windows, while echo cancellation or noise suppression is on, HayChat asks Windows for the
  microphone's raw signal, so Windows' own processing (noise suppression, a laptop's
  microphone array) does not run underneath HayChat's. That also applies to the speakers, and
  a laptop's built-in microphones can sound quieter: raise **Input gain** if they do. Turning
  both off gives Windows its processing back (the audio devices reopen; you stay in voice).
- It is loaded when it is needed: on Linux `libhaychat-webrtc-apm.so` next to `haychat-client`
  (the release archive has it) with the distribution's webrtc-audio-processing 2.x (the
  `webrtc-audio-processing` package on Fedora and Arch; Debian 13 and Ubuntu ship only
  version 1.3, which HayChat cannot use), and `haychat-webrtc-apm.dll` next to
  `haychat-client.exe` on Windows (the release zip has it). Without it voice works, the toggle
  reads **Echo cancellation: unavailable**, and the note under it says why.

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
  switch: the server could read it). A conversation whose newest message is unencrypted shows
  **unencrypted** in the Direct Messages list.
- **Only messages their sender signed.** Every message, in a room or a conversation, is signed
  by the person who sent it, and HayChat shows it only once it checked that signature against
  the key it trusts for that person. A message that fails the check (one the server made up,
  changed, or put under someone else's name) is not shown at all. "Checking who sent this
  message…" means HayChat is still fetching the sender's key. Messages from before this was
  added (direct messages from before encryption, and every room message from before the
  update) were removed from the server.
- **"This message could not be decrypted".** The message could not be opened with the keys your
  client trusts: it was changed, sealed for someone else, sent under another key, or repeated by
  the server. The client never tries it again with other keys. "Opening encrypted message…"
  means the client is still fetching the sender's key.

## Administration

Admins are accounts holding the server's `admin` role; how to get the first one is in
[deploy/README.md "First-Time Setup"](../deploy/README.md#first-time-setup). Admins can also
give other accounts **roles** that let them manage rooms or room members, create invite codes or
approve sign-ups (see [Roles](#roles)); such an account gets the matching controls below and a
smaller Admin section.
Every other account sees none of these controls, and the server checks the permission for every
request. The rules the server enforces are in
[rooms-and-accounts.md](rooms-and-accounts.md#admin-actions).

### Rooms

Room management needs the admin role or a role with **Manage rooms**; adding and removing
members of invite rooms a role with **Manage room members**. In the selected server's sidebar,
the **Channels** header shows **+ New room**, which opens a
form in the main pane: a name of 1 to 64 bytes (a leading `#` is dropped), an optional
description of up to 256 bytes, a **Type** selector (**Text**, **Voice**, **Text and voice**),
**Who can join** (**Public**, **Member invite**, **Admin invite**, **Roles** with a checkbox
per role; see
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
invite-only keeps everyone in it. Making a room a **Roles** room, or changing its roles, makes
its members exactly the roles' holders (the others leave); switching a Roles room to another mode
keeps its members. An encrypted room's access changes only from its Members page
(a manager who is an admin signs it). Its history setting is shown but cannot change. The form warns before a save that would remove people from a room's
voice, and before deleting `#general` (the server recreates it only on a start with no rooms
left). It closes when another admin renames or deletes its room, and shows the server's answer
when it refuses (for example a duplicate name, or "Admin permission required" when the role was
revoked). Clients whose selected room was deleted move to `#general`, or to the first room when
`#general` is gone.

### Room Permissions

The Edit room form's **Permissions…** opens the room's **Permissions** page: a row for
**Everyone** and one per role, each with **Send messages**, **Speak in voice**, **Manage
members** and **Edit room**. A member may do what the Everyone row or any of their roles allows;
nothing takes a permission away. **Save** stores the page and everyone in the room gets the change
at once; **Back** returns to the form.

- Admins hold every room permission. A role with **Manage rooms** counts as **Edit room** in every
  room, and one with **Manage room members** as **Manage members**.
- **Edit room** lets a member open Edit room and change the name, description and type, and the
  room's permissions, but not who can join or the room's encryption, and not delete it.
- A toggle you could not change yourself is greyed out: you can only give or take away a
  permission you hold (holders of Manage rooms may give Send messages, Speak in voice and Edit
  room).
- **Manage members** in a room lets a member add and remove people there, as an admin would.

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
**Create room…**. An account that is not an admin but holds a role with **Manage rooms** or
**Manage room members** sees this room list, with the buttons its permissions allow, and one
with **Create invites** or **Approve sign-ups** sees the parts in
[Sign-up and Invites](#sign-up-and-invites); none of them sees the accounts.

### Deleting Messages

Admins can delete any room message from its right-click menu (**Delete message…**), with its
files and edit history; everyone in the room sees "Removed by the server" in its place, and its
files are logged under **Removed files** with the reason "Message deleted". Direct messages can
be deleted only by their author. See [Editing and deleting
messages](#editing-and-deleting-messages).

### Removing Files and Storage

Admins (only admins: no role grants this) can remove any file and see how much the server
stores.

- **Remove attachment…** on a file card's right-click menu asks for confirmation ("Remove NAME
  from the server? The message stays, and everyone who can read it sees "Attachment removed by
  an admin" instead of the file.") with an optional **Reason**. The server keeps the reason in
  its removal log, which admins can see under **Removed files**; nobody else sees it. The file
  is deleted from the server at once, a download in
  progress stops, and the file no longer counts toward its owner's quota. The message stays,
  and its card says "Attachment removed by an admin" for everyone who can read it.
- **Server settings → Storage**, after the Admin section, shows **Used**, **Capacity** ("No
  limit" when the server has none), **Free space** on the server's disk ("unknown" when the
  server cannot read it) and the accounts by the bytes they store, with **Refresh**. It is asked
  for again each time Server settings opens. Removed files count toward nothing.
- **Server settings → Removed files**, after Storage, lists the files removed from the server,
  newest first: when, the file's name ("Encrypted file" for an encrypted one, whose name the
  server never sees, and "File never sent" for one that was not on a message yet), whose it
  was, who removed it ("an operator" when it was removed with SQL on the server), the room or
  "Direct message", and the reason when one was given. **Load more** shows older removals and
  **Refresh** asks again; the list is asked for each time Server settings opens and after you
  remove a file. The server keeps these entries indefinitely.
- Operators without a client can do the same with SQL; see
  [deploy/README.md](../deploy/README.md#attachment-storage-and-removing-files).

### Roles

Under the accounts, admins see **Roles**: every role with what it allows and how many accounts
hold it, **New role…**, and **Edit…** on each.

- The role form has a **Name** (3 to 32 characters) and a checkbox per permission a role can
  hold: **Manage rooms**, **Manage room members**, **Create invites** and **Approve sign-ups**
  (see [Sign-up and Invites](#sign-up-and-invites)). **Create** or **Save** sends it,
  **Delete…** asks for a second click, and **Cancel** closes it.
- `admin` is built in: its form shows every permission ticked and greyed, and it has no Save or
  Delete. Admins are made with **Make admin**.
- Each account's row lists its roles ("Roles: …") and has **Roles…**, which opens a checkbox per
  role under it; a click gives or takes that role at once. The account's sessions get their new
  controls without reconnecting.
- Kicking, banning and renaming cannot be given to a role.

### Sign-up and Invites

Between **Roles** and the room list, the Admin section has three more parts:

- **Registration** (admins): **Open**, **Invite only** or **Invite + approval**, with a sentence
  saying what the mode means. A change applies at once to new sign-ups, never to existing
  accounts.
- **Invites** (accounts with **Create invites**): **New invite…** opens a form with a note, an
  expiry (1 hour to never), a number of uses (one to no limit) and, for admins, roles the new
  account gets, one room to restrict it to (unencrypted invite rooms only), and **Skip
  approval**. Others can only make plain codes that expire within 7 days. **Create code** shows
  the code once, with **Copy**, **Copy link** (an [invite link](#invite-links)) and **Done**: it
  cannot be shown again. Each code is listed with its note, who made it, its uses and expiry,
  and **Revoke** (admins revoke any code, others their own).
- **Sign-up requests** (accounts with **Approve sign-ups**): each waiting request with the name,
  the reason and the code it used, **Approve** and **Decline…** (an optional reason the person is
  shown). The number of waiting requests shows as a badge, "N pending", on this part and on the
  Admin heading, and as "⚙ N" on the sidebar gear; there is no pop-up.

An account made with a room code shows a **Restricted** badge in the account list, and admins
get **Lift restriction**, which joins it to every Public room and lets it see everyone.

A kicked or banned client says so in its banner, with the admin's reason, and neither reconnects
nor rejoins voice by itself.

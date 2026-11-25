# HayChat Tester Guide

Thank you for testing HayChat. This guide explains what HayChat is, how to install and start
it, what the messages on screen mean, what to try, and how to tell us about problems. You do
not need to be a developer. Every screen and button is described in detail in the
[user guide](user-guide.md).

## What HayChat Is

HayChat is a chat app, a bit like a small Discord, that its users host themselves. The person
who invited you (the _maintainer_) runs a HayChat server; you run the HayChat client on your
computer and connect to it. HayChat is in early development, so expect rough edges: finding
them is the point of this test.

What works today:

| Feature                              | State                                                                                                                                                                                                     |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Text rooms                           | Works. Every account is in every room; `#general` is open to everyone on the server. The maintainer (a server admin) can add, rename, and delete rooms; new rooms show up in your list by themselves      |
| Room history                         | Works. Messages are stored on the server; **Load older messages** at the top of a room fetches earlier ones, also after a restart                                                                         |
| Direct messages                      | Works. Below the rooms, the sidebar lists **Direct Messages** (recent conversations) and **Members** (everyone on the server, online first, with a green dot when online). Click a person to message them |
| Several servers                      | Works. The client can connect to more than one server at once                                                                                                                                             |
| Voice rooms                          | Works. Rooms have voice unless an admin made them text-only: **Join voice** in the room's header. See [Voice](#voice). Needs headphones for now (there is no echo cancellation)                           |
| Server settings                      | Works. The gear in a server's sidebar header: a display name for that server only, its label, and a volume slider and **Mute for me** for each person                                                     |
| Right-click menus                    | Works. Rooms, people, messages, server buttons and text fields have a menu: mark as read, copy, quote, send a message, join voice, and more                                                               |
| Editing and deleting messages        | Works. Right-click your own message for **Edit message** and **Delete message…**, or press Up in the empty message box. Edited messages say **(edited)**; rest the pointer on it for the history. See [Editing and deleting messages](user-guide.md#editing-and-deleting-messages) |
| Creating rooms                       | Only for the maintainer and other admins. Testers do not see the **+ New room** and **Edit room** controls; ask the maintainer for a room                                                                 |
| Files                                | Works. The paperclip left of the message box (or dropping files on the window) attaches up to four files to a message; **Save…** on a file saves it. HayChat never opens or previews files. See [Files](user-guide.md#files) |
| Changing your password               | Not in the client (there are no passwords: see [Your Identity](#your-identity))                                                                                                                            |

> [!IMPORTANT]
> Messages are encrypted between your computer and the server. Direct messages are also
> **end-to-end encrypted** when both of you can receive encrypted messages (a 🔒 on each
> message); room messages are **not**: the server stores them in plain text, and the maintainer
> can read them, like any direct message marked "Unencrypted". Do not send anything in a room
> you would not want the maintainer to see. Every message is signed by its sender, so the
> server cannot make one up in your name.

## Getting the Client

### Download (recommended)

Open the releases page, <https://git.spyingwind.com/quonic/haychat/releases>, and download the
newest release for your system:

- **Windows:** `haychat-client-VERSION-windows-x86_64.zip`. Extract the whole zip into a folder
  (the `.dll` files must stay next to `haychat-client.exe`) and double-click
  `haychat-client.exe`. Test builds are not signed, so Windows SmartScreen may say the app is
  from an unknown publisher: choose **More info**, then **Run anyway**. A console window with
  the client's log opens next to the HayChat window; leave it open, it helps with bug reports.
- **Linux:** `haychat-client-VERSION-linux-x86_64.tar.gz`. Install the libraries it needs
  first:

  | Distribution              | Command                                                     |
  | ------------------------- | ----------------------------------------------------------- |
  | Fedora 44                 | `sudo dnf install SDL3 SDL3_ttf enet opus`                  |
  | Ubuntu 25.04+, Debian 13+ | `sudo apt install libsdl3-0 libsdl3-ttf0 libenet7 libopus0` |
  | Arch Linux                | `sudo pacman -S sdl3 sdl3_ttf enet opus`                    |

  Then extract the archive and start `./haychat-client` from the extracted folder. Older
  distributions such as Ubuntu 24.04 do not have SDL3 yet; build from source instead, or ask
  the maintainer.

- **macOS** is not supported yet.

`README.txt` inside each download repeats these steps. `THIRD_PARTY_NOTICES.txt`, `LICENSE.txt`
and the `licenses` folder hold the licences and credits of HayChat and the code and fonts it
includes; keep them with the app if you pass it on.

### Build From Source

If there is no download for your system, or the maintainer asks you to test a newer version,
you can build the client. This needs the Odin compiler at the exact version HayChat pins and
takes about ten minutes the first time. On Linux with podman installed, the simplest way is:

```sh
git clone https://git.spyingwind.com/quonic/haychat.git
cd haychat
./dev.sh shell                                # opens a shell in the build container
odin build client -o:speed -out:haychat-client
exit
./haychat-client                              # needs the libraries listed above
```

On Windows, follow "Building the Windows Client on Windows" in
[deploy/README.md](../deploy/README.md).

## First Run

The first time the client starts, it shows a setup screen:

1. **Display name.** The name other people see. It must be 3 to 32 bytes long: ordinary
   letters and digits count 1 each, accented letters 2, and emoji 2 to 4, so a name with
   emoji may be shorter than you expect.
2. **Server host** and **Port.** Enter exactly what the maintainer gave you, for example
   `chat.example.org` and `12345`. You can also type `chat.example.org:12345` into the host
   field.
3. Press **Connect**.

The server **reserves a name for the first computer that uses it**. Once you have connected as
`alice`, nobody else can use `alice` on that server, and neither can you from a second
computer: each installation has its own identity. If you want to test on two computers, use
two names, for example `alice` and `alice-laptop`.

To add, edit, or remove a server later, open **Settings** with the gear button at the bottom
of the narrow server bar on the left.

**You can change your name later** in **Settings**. The client reconnects, and each server
renames your account: you keep the same rooms and direct messages, and other people see the
new name straight away. The new name must be free; if another account has it, you get "The
name … is already in use on this server" and should pick another one. Messages other people
already have on screen keep the name you sent them with until their client loads that
history again (for example after a restart).

### Your Identity

There is no password. On first start the client creates a private identity key and stores it
in its config file:

- Linux: `~/.config/haychat/config.json`
- Windows: `%APPDATA%\haychat\config.json`

That key is what proves to the server that you are you. Do not share the file. If you delete
it, the client makes a new key, and the server will no longer let you use your old name: pick
a new one, or ask the maintainer to free the old one.

### Invite Codes

A server may let people join only with an invite code. Then, instead of the rooms, the client
shows **Sign up on …** with a field for the code: paste the code the maintainer gave you and
press **Sign up**. If someone has to approve sign-ups, also say in a few words who you are; the
client then shows **Waiting for approval** until they do (keep it open, or press **Check again**
later). An invite link (`haychat://…/invite/…`) fills the code in for you after you confirm the
server; to open such links with HayChat, run `haychat-client --register-url-handler` once. If you were given a code for a server where anyone may join, tick **I have an invite
code** when you add the server, so the code's roles or room apply to your new account. See the
[user guide](user-guide.md#signing-up).

## What You See on Screen

The narrow bar on the left lists your servers. A **dot** on each server button shows its
connection:

| Dot   | Meaning                                                   |
| ----- | --------------------------------------------------------- |
| Green | Connected                                                 |
| Amber | Connecting, or waiting before the next attempt            |
| Red   | Stopped: something needs your attention (read the banner) |

At the bottom of the room list, a status line repeats the state of the selected server, for
example "Connected as alice", "Connecting…", or "Reconnecting in 4 s".

While the selected server is not connected, a **banner** above the room explains why:

| Banner                                                             | What it means                                                                                                                                                                                                    | What to do                                                                                                                                                |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Connecting to …"                                                  | The client is trying to reach the server                                                                                                                                                                         | Wait a few seconds                                                                                                                                        |
| "Could not connect to …" / "Disconnected from …", with a countdown | The server cannot be reached or the connection dropped. The client tries again after 1, 2, 4, … seconds, up to every 30 seconds                                                                                  | Nothing; it reconnects by itself when the server is back. **Retry now** skips the wait. If it never connects, check the host and port with the maintainer |
| "The name … is already in use on this server"                      | Someone else, or another of your computers, already has that name                                                                                                                                                | Open **Settings** and choose another name                                                                                                                 |
| "The server's identity key does not match the one pinned for it"   | The server presents a different identity than the first time you connected. That is expected after the maintainer reset or reinstalled the server, but it could also mean someone is pretending to be the server | Ask the maintainer whether the server was reset. Only then press **Trust the new key**                                                                    |
| "This client and the server speak different protocol versions"     | Your client is older or newer than the server                                                                                                                                                                    | Download the client version that matches the server                                                                                                       |
| "Display names must be 3 to 32 bytes long"                         | The name in Settings is too short or too long                                                                                                                                                                    | Change it in **Settings**                                                                                                                                 |
| "An admin removed you from this server"                            | An admin kicked your account; the reason, if any, is shown. The client does not reconnect by itself                                                                                                             | Press **Retry now** when you want to come back                                                                                                            |
| "This account is banned from this server"                          | An admin banned your account; the reason, if any, is shown                                                                                                                                                       | Ask the maintainer; you can connect again once the ban is lifted                                                                                          |

When the server restarts, every client reconnects on its own; you should not need to do
anything.

## Voice

Rooms have voice as well as text, unless an admin made a room text-only (it has no **Join
voice**) or voice-only (it has no message box). You can be in one room's voice at a time, on
one server, and keep chatting anywhere while you are.

- **Joining:** open a room and press **Join voice** at the top right. The **voice bar** at the
  bottom of the room list shows "Joining…", then "Voice connected: #room on Server". Under
  the room in the list you see everyone in its voice; a green ring around the dot means that
  person is speaking. This list also shows rooms you are not in.
- **Mute and deafen:** **Mute** in the voice bar stops sending your microphone at once;
  **Deafen** stops playing the others at once (and mutes you). The others see "muted" or
  "deafened" next to your name. **Leave** (or **Leave voice** in the room's header) leaves.
- **Headphones:** HayChat has **no echo cancellation** yet. With speakers, your microphone
  picks up the others and they hear themselves. Use headphones. On Linux,
  `pactl load-module module-echo-cancel` can help if you must use speakers.
- **Noise suppression:** on by default (Settings → Voice). It removes fans, hum and other
  steady background noise from your microphone, and in voice activity mode only speech opens
  it. Loud typing can still get through. On Linux it needs the `rnnoise` package (Fedora,
  Arch; `librnnoise0` on Debian testing); without it the setting says "unavailable" and voice
  works as before.
- **Settings → Voice:** choose the microphone and speakers (or "System default"), the mode,
  and the levels. **Test microphone** plays your microphone back to you through the same
  codec, so you can set the **voice activity threshold** against the live level meter (the
  line on the meter) without joining a room.
- **Voice activity or push-to-talk:** by default HayChat sends while you speak louder than the
  threshold. In **Push-to-talk** mode it sends only while you hold the push-to-talk key
  (Left Ctrl unless you change it). It also works while another window has focus (turn
  **In other windows too** off in Settings → Voice if you do not want that). On Windows and
  on Linux with X11 HayChat follows the key itself. On Linux with Wayland your desktop
  handles it: the first time you use push-to-talk in voice it asks you to confirm a shortcut
  (pick one if Left Ctrl is not offered), and Settings → Voice shows the one it set. A
  push-to-talk key that types (a letter, a digit or Space) does nothing while you are typing
  in a HayChat text field, but opens your microphone while you type in other windows, so a
  key such as Ctrl or an F-key works best.
- **Linux needs libopus:** the `opus` package on Fedora and Arch, `libopus0` on Debian and
  Ubuntu (it is in the install commands above). Without it the voice bar says "Voice
  unavailable: libopus not found" and chat still works.
- **Reconnects:** if the connection drops while you are in voice, the voice bar says
  "Rejoining voice…" and you are back in the same room once the client reconnects.
- **Two devices:** joining voice on a second device moves you there; the first device leaves
  voice with "joined voice on another device".
- **One person too loud or too quiet:** right-click them in the room's voice list, or open the
  server's settings (the gear in its sidebar header) → **Voice**, and move their volume slider
  or choose **Mute for me**. Only you hear the change.

### When Voice Does Not Work

- **Nobody hears you, or you hear nobody:**
  - On Linux, check that libopus is installed (the voice bar says so if it is missing).
  - In **Settings → Voice**, check that the right microphone and speakers are chosen.
  - Check that you are not muted or deafened.
  - Open **Test microphone** and speak: the meter should move, and its bar should cross the
    threshold line while you talk. If it stays under the line, move the **voice activity
    threshold** to the left (lower) or raise the **input gain**.
- **The start of your words is cut off:** your microphone is quiet. Raise the input gain or
  lower the threshold until normal speech is well past the line, or use push-to-talk.
- **Others hear your room (a fan, typing) all the time:** check that **Noise suppression** is
  on in Settings → Voice. If they still do, the threshold is too low: move it to the right
  until the meter stays under the line while you are silent.
- **Choppy or robotic sound:** usually the network. Tell us your connection (Wi-Fi or cable,
  how far from the server) and whether it happens to everyone in the room or one person.
- **Others hear an echo of themselves:** somebody is using speakers. HayChat has no echo
  cancellation; that person should use headphones.

When you report a voice problem, include a screenshot of **Settings → Voice** (devices, mode,
threshold and the meter while you talk), the text of the voice bar, and the client log. If you
run the headless client, the output of its `voice-stats` command helps too.

## What to Test

Use HayChat as you would use any chat app, and keep an eye on these:

- **Connecting:** first start, the setup screen, and connecting to the server. Try a wrong
  host or port on purpose, then correct it in Settings.
- **Chatting in `#general`:** send messages, long messages, emoji, accented letters, and text
  in other scripts. Check that everyone sees them with the right name and time.
- **History:** close the client, reopen it, and check that old messages are there. In a busy
  room, press **Load older messages** at the top and check nothing is missing or doubled.
- **Reconnecting:** put your computer to sleep, switch networks, or ask the maintainer to
  restart the server. The client should reconnect without you doing anything, and no
  messages should be missing or doubled.
- **Names:** try a name somebody else already uses; you should get a clear message. Change
  your own name in **Settings**; the others should see the new name under **Members** and
  **Direct Messages** without restarting, and your rooms and conversations should still be
  there.
- **Direct messages:** click another tester under **Members** and message them. Check that
  both of you see the conversation, that it moves to the top of **Direct Messages** with an
  unread count when you are looking at something else, and that it is still there after
  restarting the client.
- **Unread counts:** rooms and conversations show a bold name and a count of messages you
  have not read yet. Check that a count is still there after you restart the client, that it
  clears once you open the room or conversation (with the HayChat window focused), and, if
  you can sign in on two computers with the same identity, that reading on one clears the
  count on the other. Your own messages should never count.
- **Voice:** join a room's voice with another tester (with headphones), talk, mute, deafen,
  and leave. Check that the speaking ring follows whoever talks, that mute and deafen show
  for the others, and that voice comes back by itself after a reconnect. Try push-to-talk
  (also while another window, such as a game or browser, has focus),
  a different microphone in **Settings → Voice** while you are in a room, and **Test
  microphone**. Tell us about delay, choppy sound, echo, or a level meter that does not move.
- **Server settings:** open a server's settings with the gear in its sidebar header. Give
  yourself a different name on that server only, change its label, and set another person's
  voice volume or mute them for yourself while you are both in voice.
- **Files:** attach a file or a few (the paperclip, or drag them onto the window), with and
  without text, in a room and in a direct message, and save the other person's with **Save…**.
  Check that the saved file opens and is the same as the original, that a file over the
  server's limit is refused before it uploads, and that **Cancel** stops a save. Tell us which
  system's save and open dialogs you used and whether they worked.
- **Editing and deleting:** edit your own messages from their menu and with Up in the empty
  message box, in a room and in a direct message; check that the others see the new text with
  **(edited)**, that resting on **(edited)** lists every version, that Esc cancels and your
  half-typed message comes back, and that **Delete message…** leaves "Message deleted" for
  everyone. Tell us if an edit or a delete ever shows on one computer and not on another.
- **Right-click menus:** right-click rooms, people, messages, the server buttons and the message
  box. Try copy, quote, mark as read and send message, and moving through a menu with the arrow
  keys, Enter and Esc.
- **The window:** resizing, high-DPI screens, typing with an input method (for example
  Japanese or Chinese), copy and paste.

Anything confusing counts as a problem worth reporting, not only crashes.

## Reporting Problems

Open an issue at <https://git.spyingwind.com/quonic/haychat/issues> (you need an account on that
site; if you do not have one, send the same details to the maintainer directly). Please
include:

1. **What you did**, step by step, so someone else can do the same.
2. **What you expected** and **what happened instead**. A screenshot helps.
3. **The client's log.** Start the client from a terminal so you can copy its output:
   - Linux: `./haychat-client 2>&1 | tee haychat.log`, then attach `haychat.log`.
   - Windows: copy the text from the console window that opens with the client, or start it
     from PowerShell in its folder with `.\haychat-client.exe *> haychat.log` and attach
     `haychat.log`.
4. **Your system:** Windows or Linux (and which distribution), and the HayChat version (the
   release name you downloaded).
5. **The time it happened**, with your time zone, so the maintainer can find it in the
   server's log.

Never attach your `config.json`: it holds your private identity key. The log does not contain
it.

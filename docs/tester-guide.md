# HayChat Tester Guide

Thank you for testing HayChat. This guide explains what HayChat is, how to install and start
it, what the messages on screen mean, what to try, and how to tell us about problems. You do
not need to be a developer.

## What HayChat Is

HayChat is a chat app, a bit like a small Discord, that its users host themselves. The person
who invited you (the *maintainer*) runs a HayChat server; you run the HayChat client on your
computer and connect to it. HayChat is in early development, so expect rough edges: finding
them is the point of this test.

What works today:

| Feature | State |
| --- | --- |
| Text rooms | Works. Every account is in every room; `#general` is open to everyone on the server |
| Room history | Works. Messages are stored on the server; **Load older messages** at the top of a room fetches earlier ones, also after a restart |
| Direct messages | Works. Below the rooms, the sidebar lists **Direct Messages** (recent conversations) and **Members** (everyone on the server, online first, with a green dot when online). Click a person to message them |
| Several servers | Works. The client can connect to more than one server at once |
| Voice rooms | Not yet |
| Creating rooms, changing your password, file uploads | Not in the client yet (there are no passwords: see [Your Identity](#your-identity)) |

> [!IMPORTANT]
> Messages are encrypted between your computer and the server, but they are **not end-to-end
> encrypted**. The server stores every message in plain text, and the maintainer can read
> them. Do not send anything you would not want the maintainer to see.

## Getting the Client

### Download (recommended)

Open the releases page, <https://git.spyingwind.com/jim/haychat/releases>, and download the
newest release for your system:

- **Windows:** `haychat-client-VERSION-windows-x86_64.zip`. Extract the whole zip into a folder
  (the `.dll` files must stay next to `haychat-client.exe`) and double-click
  `haychat-client.exe`. Test builds are not signed, so Windows SmartScreen may say the app is
  from an unknown publisher: choose **More info**, then **Run anyway**. A console window with
  the client's log opens next to the HayChat window; leave it open, it helps with bug reports.
- **Linux:** `haychat-client-VERSION-linux-x86_64.tar.gz`. Install the libraries it needs
  first:

  | Distribution | Command |
  | --- | --- |
  | Fedora 44 | `sudo dnf install SDL3 SDL3_ttf enet` |
  | Ubuntu 25.04+, Debian 13+ | `sudo apt install libsdl3-0 libsdl3-ttf0 libenet7` |
  | Arch Linux | `sudo pacman -S sdl3 sdl3_ttf enet` |

  Then extract the archive and start `./haychat-client` from the extracted folder. Older
  distributions such as Ubuntu 24.04 do not have SDL3 yet; build from source instead, or ask
  the maintainer.
- **macOS** is not supported yet.

`README.txt` inside each download repeats these steps.

### Build From Source

If there is no download for your system, or the maintainer asks you to test a newer version,
you can build the client. This needs the Odin compiler at the exact version HayChat pins and
takes about ten minutes the first time. On Linux with podman installed, the simplest way is:

```sh
git clone https://git.spyingwind.com/jim/haychat.git
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

**Choose your name carefully: you cannot change it yet.** A server keeps exactly one name for
each identity, so after you have connected once, the server refuses any other name from your
client with "The name … is already in use on this server", even when nobody else has that
name. If you see that after editing your name in Settings, change it back.

### Your Identity

There is no password. On first start the client creates a private identity key and stores it
in its config file:

- Linux: `~/.config/haychat/config.json`
- Windows: `%APPDATA%\haychat\config.json`

That key is what proves to the server that you are you. Do not share the file. If you delete
it, the client makes a new key, and the server will no longer let you use your old name: pick
a new one, or ask the maintainer to free the old one.

## What You See on Screen

The narrow bar on the left lists your servers. A **dot** on each server button shows its
connection:

| Dot | Meaning |
| --- | --- |
| Green | Connected |
| Amber | Connecting, or waiting before the next attempt |
| Red | Stopped: something needs your attention (read the banner) |

At the bottom of the room list, a status line repeats the state of the selected server, for
example "Connected as alice", "Connecting…", or "Reconnecting in 4 s".

While the selected server is not connected, a **banner** above the room explains why:

| Banner | What it means | What to do |
| --- | --- | --- |
| "Connecting to …" | The client is trying to reach the server | Wait a few seconds |
| "Could not connect to …" / "Disconnected from …", with a countdown | The server cannot be reached or the connection dropped. The client tries again after 1, 2, 4, … seconds, up to every 30 seconds | Nothing; it reconnects by itself when the server is back. **Retry now** skips the wait. If it never connects, check the host and port with the maintainer |
| "The name … is already in use on this server" | Someone else, or another of your computers, already has that name. You also see this after changing your own name: see [First Run](#first-run) | Open **Settings** and choose another name (or your original one) |
| "The server's identity key does not match the one pinned for it" | The server presents a different identity than the first time you connected. That is expected after the maintainer reset or reinstalled the server, but it could also mean someone is pretending to be the server | Ask the maintainer whether the server was reset. Only then press **Trust the new key** |
| "This client and the server speak different protocol versions" | Your client is older or newer than the server | Download the client version that matches the server |
| "Display names must be 3 to 32 bytes long" | The name in Settings is too short or too long | Change it in **Settings** |

When the server restarts, every client reconnects on its own; you should not need to do
anything.

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
- **Names:** try a name somebody else already uses; you should get a clear message.
- **Direct messages:** click another tester under **Members** and message them. Check that
  both of you see the conversation, that it moves to the top of **Direct Messages** with an
  unread count when you are looking at something else, and that it is still there after
  restarting the client. Unread counts start at zero each time the client starts.
- **The window:** resizing, high-DPI screens, typing with an input method (for example
  Japanese or Chinese), copy and paste.

Anything confusing counts as a problem worth reporting, not only crashes.

## Reporting Problems

Open an issue at <https://git.spyingwind.com/jim/haychat/issues> (you need an account on that
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

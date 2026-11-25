HayChat client @VERSION@ for Linux (x86-64)
===========================================

HayChat is an early test build of a self-hosted chat app. The tester guide explains what
works and what to try:
https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/tester-guide.md

1. Install the libraries the client uses
----------------------------------------

The client needs SDL3, SDL3_ttf, ENet and libopus from your distribution:

  Fedora 44:                      sudo dnf install SDL3 SDL3_ttf enet opus
  Ubuntu 25.04+ / Debian 13+:     sudo apt install libsdl3-0 libsdl3-ttf0 libenet7 libopus0
  Arch Linux:                     sudo pacman -S sdl3 sdl3_ttf enet opus

libopus (libopus.so.0) is the voice codec. The client loads it only when voice is used, so
text chat works without it; voice then reports that libopus was not found.

Optional: RNNoise (librnnoise.so.0, version 0.2) removes background noise from your
microphone (Settings -> Voice -> Noise suppression). Without it voice works, and the setting
says that noise suppression is unavailable.

  Fedora 44:                      sudo dnf install rnnoise
  Debian testing / unstable:      sudo apt install librnnoise0
  Arch Linux:                     sudo pacman -S rnnoise

Debian 13 and Ubuntu do not package RNNoise 0.2 yet; voice works there without it.

Push-to-talk in other windows loads libX11 (on X11) or libdbus-1 (on Wayland, for the
desktop's GlobalShortcuts portal) when you first use it in voice; every desktop has them.

Older distributions (Ubuntu 24.04, Debian 12) do not package SDL3; build the client from
source instead (see the tester guide). The client also needs glibc 2.34 or newer.

2. Run it
---------

  ./haychat-client

To keep a log for a bug report, run it like this instead and attach haychat.log:

  ./haychat-client 2>&1 | tee haychat.log

On the first start, enter a display name and the server host and port the server's
maintainer gave you, then press Connect.

To open haychat:// invite links with HayChat, run this once (and again after moving the
folder). It adds haychat.desktop to ~/.local/share/applications for your user only:

  ./haychat-client --register-url-handler

Your settings and your identity key are stored in ~/.config/haychat/config.json (or
$XDG_CONFIG_HOME/haychat/config.json). The identity key is what lets the server recognise
you: keep that file private, and do not copy it to another person.

Licences and credits
--------------------

HayChat is licensed under the GNU AGPL v3 (LICENSE.txt). Its source code is at
https://git.spyingwind.com/quonic/haychat (this build is tag @VERSION@).

THIRD_PARTY_NOTICES.txt lists the third-party code and fonts in this download, their
licences, and their copyright lines; the licence texts are in licenses/. They cover the
Odin core library, the ENet library, and the embedded Inter and Twemoji fonts. SDL3,
SDL3_ttf, ENet, libopus and RNNoise themselves come from your distribution, with its licences.

Emoji: Twemoji by Twitter, Inc. and contributors — CC-BY 4.0 — https://twemoji.twitter.com

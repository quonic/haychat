HayChat client @VERSION@ for Linux (x86-64)
===========================================

HayChat is an early test build of a self-hosted chat app. The tester guide explains what
works and what to try:
https://git.spyingwind.com/jim/haychat/src/branch/main/docs/tester-guide.md

1. Install the libraries the client uses
----------------------------------------

The client needs SDL3, SDL3_ttf and ENet from your distribution:

  Fedora 44:                      sudo dnf install SDL3 SDL3_ttf enet
  Ubuntu 25.04+ / Debian 13+:     sudo apt install libsdl3-0 libsdl3-ttf0 libenet7
  Arch Linux:                     sudo pacman -S sdl3 sdl3_ttf enet

Older distributions (Ubuntu 24.04, Debian 12) do not package SDL3; build the client from
source instead (see the tester guide). The client also needs glibc 2.34 or newer.

2. Run it
---------

  ./haychat-client

To keep a log for a bug report, run it like this instead and attach haychat.log:

  ./haychat-client 2>&1 | tee haychat.log

On the first start, enter a display name and the server host and port the server's
maintainer gave you, then press Connect.

Your settings and your identity key are stored in ~/.config/haychat/config.json (or
$XDG_CONFIG_HOME/haychat/config.json). The identity key is what lets the server recognise
you: keep that file private, and do not copy it to another person.

Licences
--------

HayChat is licensed under the GNU AGPL v3 (LICENSE.txt). The embedded Inter and Twemoji
fonts and the ENet library are covered by the licences in licenses/.

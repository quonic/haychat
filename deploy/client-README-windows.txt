HayChat client @VERSION@ for Windows (x86-64)
=============================================

HayChat is an early test build of a self-hosted chat app. The tester guide explains what
works and what to try:
https://git.spyingwind.com/jim/haychat/src/branch/main/docs/tester-guide.md

Run it
------

1. Extract the whole zip into a folder. haychat-client.exe needs SDL3.dll and SDL3_ttf.dll
   next to it.
2. Double-click haychat-client.exe. Windows SmartScreen may warn that the app is from an
   unknown publisher, because test builds are not signed: choose "More info", then
   "Run anyway".
3. On the first start, enter a display name and the server host and port the server's
   maintainer gave you, then press Connect.

A console window opens next to the HayChat window. It shows the client's log: if something
goes wrong, copy its text into your bug report before you close it. To save the log to a
file instead, open PowerShell in the folder and run:

  .\haychat-client.exe *> haychat.log

Your settings and your identity key are stored in %APPDATA%\haychat\config.json. The
identity key is what lets the server recognise you: keep that file private, and do not copy
it to another person.

This build is cross-compiled from Linux and has had less testing than the Linux build.
Please report anything that behaves differently from Linux.

Licences
--------

HayChat is licensed under the GNU AGPL v3 (LICENSE.txt). SDL3 and SDL3_ttf (zlib licence),
the FreeType, HarfBuzz, PlutoSVG and PlutoVG code inside SDL3_ttf.dll, the ENet library, and
the embedded Inter and Twemoji fonts are covered by the licences in licenses\.

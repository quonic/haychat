HayChat client @VERSION@ for Windows (x86-64)
=============================================

HayChat is an early test build of a self-hosted chat app. The tester guide explains what
works and what to try:
https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/tester-guide.md

Run it
------

1. Extract the whole zip into a folder. haychat-client.exe needs SDL3.dll and SDL3_ttf.dll
   next to it. libopus-0.dll, also in the folder, is the voice codec; without it text chat
   still works and voice reports that libopus was not found. rnnoise.dll removes background
   noise from your microphone (Settings -> Voice -> Noise suppression); without it voice
   works without noise suppression. haychat-webrtc-apm.dll cancels the echo of the voices
   HayChat plays, so others do not hear themselves through your speakers (Settings -> Voice
   -> Echo cancellation), and while it runs also does the noise suppression; without it voice works
   without echo cancellation. While either is on, HayChat asks Windows for the microphone's
   raw signal, without Windows' own processing, so a laptop's built-in microphones can sound
   quieter: raise Input gain if they do.
2. Double-click haychat-client.exe. Windows SmartScreen may warn that the app is from an
   unknown publisher, because test builds are not signed: choose "More info", then
   "Run anyway".
3. On the first start, enter a display name and the server host and port the server's
   maintainer gave you, then press Connect.
4. To open haychat:// invite links with HayChat, open PowerShell in the folder and run this
   once (and again after moving the folder). It changes the registry for your user only:

     .\haychat-client.exe --register-url-handler

A console window opens next to the HayChat window. It shows the client's log: if something
goes wrong, copy its text into your bug report before you close it. To save the log to a
file instead, open PowerShell in the folder and run:

  .\haychat-client.exe *> haychat.log

Your settings and your identity key are stored in %APPDATA%\haychat\config.json. The
identity key is what lets the server recognise you: keep that file private, and do not copy
it to another person.

This build is cross-compiled from Linux and has had less testing than the Linux build.
Please report anything that behaves differently from Linux.

Licences and credits
--------------------

HayChat is licensed under the GNU AGPL v3 (LICENSE.txt). Its source code is at
https://git.spyingwind.com/quonic/haychat (this build is tag @VERSION@).

THIRD_PARTY_NOTICES.txt lists the third-party code and fonts in this download, their
licences, and their copyright lines; the licence texts are in licenses\. They cover SDL3 and
SDL3_ttf (zlib licence), the HIDAPI, yuv2rgb and fdlibm code inside SDL3.dll, the FreeType,
HarfBuzz, PlutoSVG and PlutoVG code inside SDL3_ttf.dll, libopus (BSD licence), RNNoise in
rnnoise.dll (BSD licence), WebRTC audio processing (BSD licence and Google's patent grant)
and Abseil (Apache licence 2.0) in haychat-webrtc-apm.dll, the ENet library, the Odin core
library, and the embedded Inter and Twemoji fonts.

This software is based in part on the work of the FreeType Team.
Portions of this software are copyright © 2023 The FreeType Project (www.freetype.org).
All rights reserved.

Emoji: Twemoji by Twitter, Inc. and contributors — CC-BY 4.0 — https://twemoji.twitter.com

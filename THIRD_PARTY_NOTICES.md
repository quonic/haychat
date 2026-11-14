# Third-Party Notices

HayChat is licensed under the GNU Affero General Public License v3 (`LICENSE`). Its release
builds also contain code, libraries and fonts from other projects. This file lists them for
each release artifact, with their licences, copyright lines, and the credits those licences
ask for. It ships as `THIRD_PARTY_NOTICES.txt` in every release archive and in the server
image (`/usr/share/licenses/haychat-server/`). The full licence texts it refers to are in the
`licenses/` folder next to it; notices that exist only as source comments are reproduced in
full at the end of this file.

The source code of HayChat is at <https://git.spyingwind.com/jim/haychat>; each release is a
tag of that repository.

## Required Credits

**FreeType** (Windows client only: `SDL3_ttf.dll` contains FreeType 2.13.2):

> This software is based in part on the work of the FreeType Team.
>
> Portions of this software are copyright © 2023 The FreeType Project (www.freetype.org).
> All rights reserved.

**Twemoji** (both clients embed the Twemoji-Mozilla emoji font):

> Twemoji by Twitter, Inc. and contributors — CC-BY 4.0 — https://twemoji.twitter.com

## What Each Artifact Contains

"Linked from the system" means the artifact does not contain that library: the binary loads
the copy installed on the machine, which comes with its own licence from the distribution.

| Component | Licence | Server archive | Server image | Linux client | Windows client |
| --- | --- | --- | --- | --- | --- |
| Odin core and base library | zlib (Odin) | compiled in | compiled in | compiled in | compiled in |
| Third-party code in Odin core (below) | various | compiled in | compiled in | compiled in | compiled in |
| odin-postgresql (`pg`) | MIT | compiled in | compiled in | - | - |
| ENet | MIT | system | Fedora `enet` | system | compiled in |
| libpq (PostgreSQL client) | PostgreSQL | system | Fedora `libpq` | - | - |
| SDL3 | zlib | - | - | system | `SDL3.dll` |
| Third-party code in SDL3 (below) | various | - | - | system | in `SDL3.dll` |
| SDL3_ttf | zlib | - | - | system | `SDL3_ttf.dll` |
| FreeType 2.13.2 | FreeType License | - | - | system | in `SDL3_ttf.dll` |
| HarfBuzz 8.5.0 | Old MIT | - | - | system | in `SDL3_ttf.dll` |
| PlutoSVG, PlutoVG | MIT | - | - | system | in `SDL3_ttf.dll` |
| Opus (libopus) | BSD-3-Clause | - | - | system, at runtime | `libopus-0.dll` |
| Inter fonts | SIL OFL 1.1 | - | - | embedded | embedded |
| Twemoji-Mozilla font | CC BY 4.0 | - | - | embedded | embedded |
| Microsoft C runtime | Visual Studio licence | - | - | - | compiled in |

The server image is Fedora (`fedora-minimal:44`); every Fedora package in it, including
`libpq`, `enet` and their dependencies, has its licence under `/usr/share/licenses/<package>`.

## Components

### Odin

The Odin compiler's `base` and `core` libraries and the `vendor` bindings are compiled into
every HayChat binary.

- Licence: zlib-style (`licenses/Odin-LICENSE.txt`)
- Copyright (c) 2016-2025 Ginger Bill. All rights reserved.
- Required in binaries: nothing (an acknowledgement is appreciated).

Parts of `core` are by other Odin contributors (zhibog, Jeroen van Rijn, Tetralux, Colin
Davidson, Feoramund, eisbehr, Christiano Haesbaert) and are made available under Odin's
licence.

### Third-Party Code in Odin's Core Library

These parts of `base` and `core` come from other projects and reach HayChat binaries. The
optimiser inlines or drops much of it, so not every routine below is in every binary; the
notices are kept for all of them.

| Code | Origin | Licence | Required in binaries |
| --- | --- | --- | --- |
| `runtime.fixuint`, `runtime.fixint` | LLVM compiler-rt | Apache-2.0 WITH LLVM-exception | nothing (LLVM exception); text in `licenses/compiler-rt-LICENSE.txt` |
| `core:math` rounding | Go (`src/math/floor.go`) | BSD-3-Clause | the notice ([Go](#go-bsd-3-clause)) |
| `core:math` elementary functions | fdlibm (Sun Microsystems), via FreeBSD msun | fdlibm notice | the notice ([fdlibm](#fdlibm)) |
| `core:math` gamma, sine and cosine | Cephes Math Library (Stephen L. Moshier) | Cephes terms | none stated ([Cephes](#cephes)) |
| `core:unicode` tables | Unicode Character Database | Unicode License V3 | the notice ([Unicode](#unicode-license-v3)) |
| `core:crypto` field arithmetic | fiat-crypto | BSD-1-Clause | nothing (source only) ([fiat-crypto](#fiat-crypto-bsd-1-clause)) |
| `core:crypto` constant-time helpers | BearSSL (Thomas Pornin) | BSD-style, source clause only | nothing (source only) ([BearSSL](#bearssl)) |
| `core:strconv` float parsing | fast_float, ffc.h | BSL-1.0 | nothing for object code |
| `core:strconv` float printing | Żmij (Victor Zverovich) | BSL-1.0 | nothing for object code |
| `core:hash` CRC-64 (server) | Mark Adler | zlib | nothing |
| `core:math/big` | LibTomMath; BPSW test by Thomas R. Nicely | public domain | nothing |
| ChaCha20 SIMD, SHA-256 (Intel SHA) | Ted Krovetz; Jeffrey Walton | public domain | nothing |

### odin-postgresql, `pg` (server)

- Licence: MIT (`licenses/pg-LICENSE.txt`)
- Copyright (c) 2024 Laytan (https://github.com/laytan)
- Required in binaries: the copyright and permission notice.

### ENet

- Licence: MIT (`licenses/ENet-LICENSE.txt` in the client archives)
- Copyright (c) 2002-2024 Lee Salzman
- The Windows client links ENet statically from Odin's `vendor/ENet/lib/enet64.lib`, so its
  notice is required there. The server and the Linux client use the system `libenet`.

### SDL3 and SDL3_ttf (Windows client)

- Licence: zlib (`licenses/SDL3-LICENSE.txt`, `licenses/SDL3_ttf-LICENSE.txt`)
- SDL3: Copyright (C) 1997-2026 Sam Lantinga
- SDL3_ttf 3.2.2: Copyright (C) 1997-2025 Sam Lantinga
- Required in binaries: nothing (an acknowledgement is appreciated). `SDL3.dll` and
  `SDL3_ttf.dll` are the builds that Odin's `vendor/sdl3` ships.

### Third-Party Code in SDL3 (Windows client, inside `SDL3.dll`)

`SDL3.dll` is SDL 3.4.18, the version in the pinned Odin `vendor/sdl3`. SDL compiles these
parts of other projects into it (read from SDL 3.4.18's source and `VisualC/SDL/SDL.vcxproj`,
the project SDL builds its Windows release with). The licence texts SDL keeps beside them are
copied unchanged into this repository's `deploy/licenses/`.

| Code | Origin | Licence | Required in binaries |
| --- | --- | --- | --- |
| HID device access for game controllers (`src/hidapi`) | HIDAPI (Alan Ott, Signal 11 Software) | GPL-3.0, BSD-style, or the original HIDAPI licence, at the user's choice; HayChat takes the **BSD-style** licence | the notice, `licenses/hidapi-LICENSE-bsd.txt` |
| YUV to RGB conversion (`src/video/yuv2rgb`) | yuv2rgb (Adrien Descamps) | BSD-3-Clause | the notice, `licenses/yuv2rgb-LICENSE.txt` |
| Math functions SDL does not take from the C runtime (`src/libm`) | fdlibm (Sun Microsystems) | fdlibm notice | the notice ([fdlibm, in SDL3](#fdlibm-in-sdl3)) |
| PNG and JPEG decoding (`stb_image.h` 2.30) | stb (Sean Barrett) | MIT or public domain; HayChat takes public domain | nothing |
| Deflate for PNG writing (`miniz.h` 1.15) | miniz (Rich Geldreich) | public domain (Unlicense) | nothing |
| Controller tables and Steam controller support | Valve Corporation | zlib | nothing |
| Surface rotation (`SDL_rotate.c`) | SDL_gfx (Andreas Schiffler) | zlib | nothing |
| Several HIDAPI controller and haptics drivers | their authors, named in each file | zlib | nothing |

SDL's other third-party files are interface headers (Khronos EGL, OpenGL and Vulkan; Microsoft
Direct3D 12) and code for other platforms (X11, Wayland, macOS, Android, OpenVR), which the
Windows build does not compile.

### FreeType (Windows client, inside `SDL3_ttf.dll`)

- Licence: the FreeType License (FTL), `licenses/LICENSE.freetype.txt`. FreeType is
  dual-licensed under the FTL and GPL-2.0; HayChat uses it under the FTL.
- Copyright 1996-2002, 2006 by David Turner, Robert Wilhelm, and Werner Lemberg
- Version 2.13.2, released in 2023: `TTF_GetFreeTypeVersion` in the shipped `SDL3_ttf.dll`
  reports 2.13.2.
- Required in binaries: a statement in the documentation that the software is based in part
  on the work of the FreeType Team. See [Required Credits](#required-credits).

### HarfBuzz (Windows client, inside `SDL3_ttf.dll`)

- Licence: "Old MIT" (`licenses/LICENSE.harfbuzz.txt`)
- Copyright © 2010-2022 Google, Inc., © 2005-2023 Behdad Esfahbod, © 2004-2023 Red Hat,
  Inc., and the other holders listed in the licence file
- Version 8.5.0 (`TTF_GetHarfBuzzVersion`)
- Required in binaries: the copyright notice and the two disclaimer paragraphs.

### PlutoSVG and PlutoVG (Windows client, inside `SDL3_ttf.dll`)

- Licence: MIT (`licenses/LICENSE.plutosvg.txt`, `licenses/LICENSE.plutovg.txt`)
- Copyright (c) 2020-2025 Samuel Ugochukwu
- Required in binaries: the copyright and permission notice.

### Opus (Windows client: `libopus-0.dll`)

- Licence: BSD-3-Clause (`licenses/opus-LICENSE.txt`), with the royalty-free patent licences
  listed in that file
- Copyright 2001-2011 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B.
  Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo
- Required in binaries: the copyright notice, conditions and disclaimer.
- `libopus-0.dll` is the copy Odin ships for SDL3_mixer. The Linux client loads the system
  `libopus.so.0` at runtime instead.

### Inter (both clients, embedded)

- Licence: SIL Open Font License 1.1 (`licenses/InterVariable-OFL.txt`), for both
  `InterVariable.ttf` and `Inter-Bold.ttf`
- Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)
- Required: the copyright notice and the licence travel with the font.

### Twemoji-Mozilla (both clients, embedded)

- Licence: CC BY 4.0 for the artwork (`licenses/Twemoji-Mozilla-CCBY.txt`)
- Twemoji artwork copyright Twitter, Inc. and contributors; the font is Mozilla's
  twemoji-colr build.
- Required: attribution. See [Required Credits](#required-credits).

### Microsoft C Runtime (Windows client)

The Windows client is linked with the static MSVC C runtime (`libcmt.lib`) from the Visual
Studio build tools, under Microsoft's licence terms for those tools, which permit
distributing it inside an application. They ask for no notice.

### Libraries Linked From the System

The server, the server archive, and the Linux client link these at runtime and do not
include them: glibc, libpq (PostgreSQL licence), libenet (MIT), SDL3 and SDL3_ttf (zlib)
with the FreeType, HarfBuzz and PlutoSVG they use, and libopus (BSD-3-Clause). The
distribution's packages carry their licences.

## Notice Texts

These notices exist only as source comments in the Odin toolchain or in SDL, so they are
reproduced here as they appear there.

### Go (BSD-3-Clause)

```text
Copyright (c) 2009 The Go Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### fdlibm

```text
Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.

Developed at SunSoft, a Sun Microsystems, Inc. business.
Permission to use, copy, modify, and distribute this
software is freely granted, provided that this notice
is preserved.
```

### fdlibm, in SDL3

SDL's copy (`src/libm`) carries the same notice with one word changed.

```text
Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.

Developed at SunPro, a Sun Microsystems, Inc. business.
Permission to use, copy, modify, and distribute this
software is freely granted, provided that this notice
is preserved.
```

### Cephes

```text
Cephes Math Library Release 2.8:  June, 2000
Copyright 1984, 1987, 1989, 1992, 2000 by Stephen L. Moshier

The readme file at http://netlib.sandia.gov/cephes/ says:
   Some software in this archive may be from the book _Methods and
Programs for Mathematical Functions_ (Prentice-Hall or Simon & Schuster
International, 1989) or from the Cephes Mathematical Library, a
commercial product. In either event, it is copyrighted by the author.
What you see here may be used freely but it comes with no support or
guarantee.
```

### Unicode License V3

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

### fiat-crypto (BSD-1-Clause)

```text
Copyright (c) 2015-2020 the fiat-crypto authors (see the AUTHORS file)
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

THIS SOFTWARE IS PROVIDED BY the fiat-crypto authors "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL Berkeley Software Design,
Inc. BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### BearSSL

```text
Copyright (c) 2016 Thomas Pornin <pornin@bolet.org>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.

THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Keeping This File Current

`deploy/release-artifacts.sh --check-licences` (run by `./check.sh` and at the start of every
release build) fails when a licence file this file refers to is missing from the repository or
the pinned toolchain, or when `SDL3.dll` or `SDL3_ttf.dll` changes. A new SDL may bundle other
third-party code, so the SDL3 list above and the texts in `deploy/licenses/` must be checked
against its source; a new SDL3_ttf build may carry a different FreeType, so the version and
year above must be checked again. Do both before the pin moves. After an Odin pin bump, also
look for new third-party code in the packages HayChat compiles
(`odin build ... -export-dependencies:json` lists them).

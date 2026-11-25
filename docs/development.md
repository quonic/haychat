# Development

Development runs in [podman](https://podman.io/) containers, so the host needs only podman
(`sudo dnf install podman` on Fedora, `sudo apt install podman` on Debian/Ubuntu). `./dev.sh` is
the single entry point; `./dev.sh help` lists every command. Code style, testing conventions and
the protocol rules are in [AGENTS.md](../AGENTS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).

## Quick Start

```sh
./dev.sh ci                  # build the dev image and run every check, as CI does
./dev.sh up                  # PostgreSQL + a server built from your working tree
./dev.sh client alice        # a client window; each profile is a separate user
./dev.sh client bob
./dev.sh down                # stop (data is kept), or ./dev.sh reset to start over
```

## The Dev Image

Every container uses the dev image built from `dev/Containerfile`: Fedora 44, the system
libraries HayChat links against, and the Odin toolchain and shared libraries at the commits
pinned in `dev/bootstrap-odin.sh`. The image tag is a hash of those inputs. Changing a package
(`dev/install-packages.sh`) or a pin produces a new tag, and the next `./dev.sh` command rebuilds
the image; the first build takes a few minutes.

Containers never see the repository directly. Each gets a snapshot of the working tree: tracked
files, including uncommitted edits, plus untracked files that `.gitignore` does not exclude.
Local leftovers such as `logs/`, `storage/`, built binaries, and your `~/.config/haychat` never
reach a container, and no command touches them.

Containers that run the server or the tests use podman's default seccomp profile and SELinux
label. Only `./dev.sh client` (for the host display socket) and `./dev.sh shell` (for the
read-write repository mount) run without SELinux confinement. All of them are rootless.

## Checks

| Command | What it runs |
| --- | --- |
| `./dev.sh check` | `./check.sh`: `odin check` for the server and for the client on Linux and Windows, the licence check, then every test suite with leak detection (a test fails on any leak or bad free) |
| `./dev.sh live` | `dev/live-proof.sh`: builds and starts the server against a throwaway PostgreSQL, checks that it created `#general`, loads the `server/sql/auth_bootstrap.sql` fixture, and runs the live startup auth proof |
| `./dev.sh live --all` | Also the two-client room chat, direct message and voice proofs, and every proof below |
| `./dev.sh live --harness` | `dev/harness-smoke.sh`: headless clients connect, list rooms, chat, exchange a direct message, rename, manage rooms as an admin, and check read state |
| `./dev.sh live --admin` | `dev/admin-proof.sh`: two headless clients prove the admin actions: a role change pushed live, a locked rename that survives a reconnect, a kick, a ban and its unban, and a room made text-only that ends its voice |
| `./dev.sh live --registration` | `dev/registration-proof.sh`: headless clients sign up in Invite only and Invite + approval mode: no code, an inviter's code, expired, revoked and used-up codes, an invite link, a request approved live and one declined, a room code that makes a restricted account, and the admin key on a second server with a fresh database |
| `./dev.sh live --voice` | `dev/voice-proof.sh`: two client processes send a 440 Hz tone through the server, checked by `dev/tools/voice-check`; then through SDL's disk audio driver, through injected loss (5 % dropped, up to 20 ms delay, repaired by FEC and PLC), and one voice session per user |
| `./dev.sh live --ui` | `dev/ui-smoke.sh`: the real client window on SDL's offscreen driver, driven by `--ui-script`, chats, exchanges a direct message, manages rooms, accounts, roles, invite codes and sign-up requests as an admin, uses voice and context menus, and takes screenshots (set `HAYCHAT_DEV_UI_SCREENSHOTS=DIR` to keep them) |
| `./dev.sh live --sql` | The server SQL proofs (database-backed tests gated on `HAYCHAT_DATABASE_SQL_TEST=1`) and the check that a failed startup exits with status 1 |
| `./dev.sh ci` | `check`, then `live --all`: the same steps Forgejo CI runs |

Each run gets fresh containers. `live` and `ci` also get a fresh PostgreSQL in a tmpfs, so live
test users never pile up. The throwaway pod publishes no ports, so it runs alongside the dev
environment or a host server without conflicts.

The harness and GUI automation are documented in [testing-harness.md](testing-harness.md). Voice
on real audio devices is a manual check outside CI: `dev/voice-manual-test.sh [HOST:PORT]` on a
Linux host with PipeWire, using virtual devices only; see
[voice-manual-test.md](voice-manual-test.md), which also has the Windows voice checklist.
`dev/pipewire-docs-check.sh` (manual too, needs only podman) loads every PipeWire configuration
block in [voice-linux-audio.md](voice-linux-audio.md) into a private PipeWire in a container and
checks the devices and links; run it after changing that page.

While editing, component-scoped tests are faster. Inside `./dev.sh shell`, or on a host with
`odin`: `odin test common`, `odin test client`, or `odin test server
-define:ODIN_TEST_THREADS=1`.

## The Dev Pod

`./dev.sh up` starts the pod `haychat-dev`: PostgreSQL 17 and a server built from your working
tree. The containers share the pod's network and reach each other on `127.0.0.1`. Clients
connect on `localhost:12345/udp`, the only published port.

| Command | Purpose |
| --- | --- |
| `./dev.sh up` | Build the server and start the pod |
| `./dev.sh restart` | Rebuild the server from the working tree and restart it. A compile error leaves the running server up |
| `./dev.sh status` | Containers and ports |
| `./dev.sh logs [-f]` | Server output |
| `./dev.sh seed` | Load the `server/sql/auth_bootstrap.sql` fixture (see [Seeded Test Identities](#seeded-test-identities)) |
| `./dev.sh psql [ARGS...]` | psql on the dev database |
| `./dev.sh client [PROFILE]` | Build the client and open its window on your Wayland or X11 display. Each profile has its own config and identity key. A new profile's display name is the profile name and its server is the dev server, so two profiles are two users. Profiles created before the first-run screen existed have no server: enter `localhost` once on that screen |
| `./dev.sh key [PROFILE]` | Print a profile's public key, for `HAYCHAT_ADMIN_PUBLIC_KEY` |
| `./dev.sh down` | Remove the pod. The database, server state, and client profiles are kept in volumes |
| `./dev.sh reset` | `down`, then delete those volumes. The next `up` starts with an empty database and a new server identity key |
| `./dev.sh shell` | Interactive shell in the dev image with the repository mounted read-write at `/src`, for ad-hoc `odin` commands; `./dev.sh shell CMD [ARGS...]` runs one command there without a terminal |
| `./dev.sh image [--pull]` | Rebuild the dev image; `--pull` also refreshes the Fedora base image |
| `./dev.sh release-image [--smoke]` | Build the production server image as `localhost/haychat-server:dev`; `--smoke` also runs it against a throwaway PostgreSQL, connects a headless client, and runs `deploy/sql/make-admin.sql` (see [deploy/README.md](../deploy/README.md)) |

The server keeps its logs, storage, and identity key in the `haychat-dev-state` volume, and
PostgreSQL keeps its data in `haychat-dev-pgdata`. Client profiles live in
`haychat-dev-client-<profile>` volumes. A client running on the host (`odin run client`) also
reaches the dev server, at its default `localhost:12345`.

Server settings for the pod go in `.env` (`cp .env.example .env`); see
[server-configuration.md](server-configuration.md). `./dev.sh` itself reads these environment
variables:

| Variable | Purpose |
| --- | --- |
| `HAYCHAT_DEV_PORT` | Host UDP port published for client connections (default `12345`) |
| `HAYCHAT_DEV_ENV_FILE` | Server overrides file (default `.env`) |
| `HAYCHAT_DEV_POSTGRES_IMAGE` | PostgreSQL image (default `docker.io/library/postgres:17`) |
| `HAYCHAT_DEV_UI_SCREENSHOTS` | Host directory that keeps the GUI smoke test's screenshots (BMP) from `live --ui`, `live --all` and `ci` |
| `HAYCHAT_SERVER_READY_TIMEOUT_SECS` | How long to wait for the server to report readiness. `./dev.sh up` and `restart` default to `120`; `dev/live-proof.sh` defaults to `60`, and `./dev.sh live` and `ci` pass the variable through when it is set |

## Typical Workflow

1. `./dev.sh up` to start PostgreSQL and the server. It creates `#general` by itself.
2. Open clients with `./dev.sh client alice`, `./dev.sh client bob`, and so on. A profile's
   display name is its profile name, so each profile is a distinct user.
3. To manage rooms and accounts, make a profile an admin after it connected once:
   `./dev.sh psql -v owner=alice <deploy/sql/make-admin.sql`, then reopen that client. Its
   sidebar then shows **+ New room**, and Server settings an **Admin** section.
4. After code changes, `./dev.sh restart` for the server and reopen clients to rebuild them.
5. Before pushing, run `./dev.sh ci`.
6. `./dev.sh down` when done, or `./dev.sh reset` to start over.

### Seeded Test Identities

`./dev.sh seed` loads `server/sql/auth_bootstrap.sql`, which the live proofs use as well:

- `admin` resolves to user ID `1` and holds the `admin` server role.
- `haypeer` resolves to user ID `2` and is bound to the first client key that connects with that
  nickname.
- `#general` is room ID `1`. The server creates it; loading the fixture restores its name and
  description and makes every existing account a member of it.

To connect as the fixture's `admin` instead of using `make-admin.sql`: run `./dev.sh client admin`
once to create the profile (it cannot claim `admin` yet) and close it. Put the output of
`./dev.sh key admin` in `.env` as `HAYCHAT_ADMIN_PUBLIC_KEY=...`, run `./dev.sh restart`, then run
`./dev.sh client admin` again.

## Without Containers

`./check.sh` and `dev/live-proof.sh` also run directly on a host that has `odin` on `PATH`. On
Fedora 44, `sudo dev/install-packages.sh` installs the system packages and
`dev/bootstrap-odin.sh [odin_root]` builds the pinned Odin toolchain and shared libraries.
`dev/live-proof.sh` expects a PostgreSQL it can reach through `HAYCHAT_DATABASE_*`, and that role
must be able to create and alter objects in `public` and to create and drop schemas (the SQL
proofs run in schemas of their own).

## Client Dependencies

The client draws its own immediate-mode UI (`client/ui`) with `vendor:sdl3` (windowing, input,
and the 2D renderer) and `vendor:sdl3/ttf` (text shaping and layout), both from Odin's vendor
collection. No other GUI library is needed.

- **Linux:** the dev image includes SDL3 and SDL3_ttf. On a host, install the development
  packages (`SDL3-devel SDL3_ttf-devel` on Fedora, `libsdl3-dev libsdl3-ttf-dev` on Ubuntu
  25.04+/Debian 13+).
- **Windows:** Odin's vendor collection ships the import libraries. To run the client, copy
  `SDL3.dll` from `%ODIN_ROOT%\vendor\sdl3\` and `SDL3_ttf.dll` from
  `%ODIN_ROOT%\vendor\sdl3\ttf\` next to `client.exe`. `./check.sh` type-checks the Windows client
  from Linux, but CI does not build or run it on Windows. Building on Windows is described in
  [deploy/README.md](../deploy/README.md#building-the-windows-client-on-windows).
- **Voice codec (libopus):** the client loads libopus at runtime with `core:dynlib`
  (`client/opus`) and never links it, so building needs no Opus headers or import library, and a
  client without libopus still starts and chats; voice then reports "libopus not found".
  - On Linux it opens `libopus.so.0` from the runtime package (`opus` on Fedora and Arch,
    `libopus0` on Debian/Ubuntu; not `opus-devel`), which the dev image and CI install.
  - On Windows it opens `libopus-0.dll` next to `client.exe` first, then the DLL search path:
    copy it from `%ODIN_ROOT%\vendor\sdl3\mixer\` (Odin ships it for SDL3_mixer; in a fresh Odin
    checkout it is a Git LFS file), with its licence `LICENSE.opus.txt` from the same folder. The
    release archive includes both.
  - `./check.sh` sets `HAYCHAT_REQUIRE_OPUS=1`, so the Opus and voice engine tests fail instead
    of skipping when libopus is missing; set `HAYCHAT_REQUIRE_OPUS=0` to let them skip on a host
    without it.
- **Push-to-talk hotkeys** (`client/hotkey`) load libX11 and libdbus-1 at runtime. Their tests
  need Xvfb, libXtst and dbus-daemon (in the dev image); `./check.sh` sets
  `HAYCHAT_REQUIRE_HOTKEY_TESTS=1` so they fail instead of skipping without them.

The UI fonts (Inter, under the SIL Open Font License, and Twemoji, under CC-BY 4.0) are embedded
into the client binary from `client/assets/fonts/`, where their license files live.

## Continuous Integration

HayChat is developed on Forgejo, and `.forgejo/workflows/ci.yml` runs on every push to `main` and
on every pull request. The Linux runner uses a Fedora 44 job container with a PostgreSQL 17
service. It runs `dev/install-packages.sh`, `dev/bootstrap-odin.sh`, `./check.sh`, and
`dev/live-proof.sh --all`, the same steps as `./dev.sh ci`. The Odin toolchain is cached under
`/opt/Odin` when the runner's cache is enabled; the cache is saved only after a successful run.

The job container needs no special seccomp or SELinux settings. A runner host set up for the old
web admin (an io_uring seccomp profile in `containers.conf.d/` and `--security-opt
label=disable` in the runner's `config.yml`) can drop both.

Releases are built by `.forgejo/workflows/release.yml` on tags `v*`; see [deploy/README.md
"Release Builds"](../deploy/README.md#release-builds). `deploy/release-artifacts.sh VERSION
OUT_DIR [--windows]` builds the same archives inside `./dev.sh shell`.

# HayChat

![HayChat Logo](assets/icon.png)

HayChat is a self-hosted alternative to Discord. It features encrypted client-server transport, a responsive user interface, and a modular architecture for easy extensibility.

> [!IMPORTANT]
> HayChat is currently in early development and is not yet ready for production use. The project is open-source and welcomes contributions from the community.

## Features

- Encrypted transport between client and server: Ed25519 identities, X25519 key exchange, and XChaCha20-Poly1305 packets, with the server key pinned on first connect. The server decrypts messages and stores them unencrypted in its PostgreSQL database; end-to-end encryption is not implemented yet. Each transport channel has its own keys: the handshake derives four with HKDF (control and voice, one per direction), the control channel (ENet channel 1) keeps a strict sequence counter, and the voice channel (ENet channel 2, not used yet) gets a 64-packet replay window. This key schedule arrived with protocol version 9, so clients and servers must be rebuilt together: older ones refuse each other with "Unsupported protocol version", which the client shows as the two speaking different protocol versions.
- Real-time messaging with low latency
- User-friendly interface with customizable themes
- Server chat in shared rooms, and direct messages between any two accounts on a server
- Cross-platform compatibility (Windows, Linux, macOS(planned))
- Modular architecture for easy addition of new features
- Comprehensive testing suite for reliability

## Advantages over Discord

- Open-source and self-hosted, giving users full control over their data and privacy
- Lightweight and optimized for performance, reducing resource usage
- Focus on security and privacy: self-hosted, encrypted in transit, and no data collection
- Customizable and extensible architecture, allowing users to tailor the application to their needs
- Transparent development process with community involvement and contributions

## Getting Started

Clone the repository, install podman, and run `./dev.sh ci` to build the toolchain image and run every check. See Development Environment below to run a local server and clients.

- **Testers:** [docs/tester-guide.md](docs/tester-guide.md) explains how to get the client, connect, and report problems.
- **Running a server for testers:** see [Deployment](#deployment) and [deploy/README.md](deploy/README.md).

On Linux, the client stores its config at `XDG_CONFIG_HOME/haychat/config.json`, defaulting to `$HOME/.config/haychat/config.json` when `XDG_CONFIG_HOME` is unset. Startup also migrates the original historical malformed path formula `$HOME$XDG_CONFIG_HOME/haychat/config.json`, which means older installs are recovered from either the default `$HOME$HOME/.config/haychat/config.json` shape or a custom `XDG_CONFIG_HOME` variant if that file still exists.

### Using the Client

The window opens at once; connecting happens in the background.

- **First run.** When the config has no display name or no server, the client shows a setup screen asking for a display name (3 to 32 bytes; accented letters and emoji count as 2 to 4), a server host, and a port (default `12345`; `host:port` in the host field works too). **Connect** saves the config and connects.
- **Settings.** The gear button at the bottom of the server rail opens the same screen later, to change the display name or to add, edit, or remove servers. Changing the name reconnects every server, and each server renames your account (see Display names); changing a server's address reconnects only that server and pins its key afresh.
- **Connection status.** The sidebar footer shows the selected server's status ("Connected as alice", "Connecting…", "Reconnecting in 4 s"), and a dot on each rail button shows every server's status (green connected, amber connecting or waiting, red stopped). While the selected server is not connected, a banner above the room explains why, with a **Retry now** button.
- **Reconnecting.** After a lost connection or a failed attempt the client retries after 1 s, 2 s, 4 s, and so on, capped at 30 s, each shortened by up to 20% of random jitter so clients do not all return at once. Restarting the server therefore reconnects every client without user action.
- **Failures that stop retrying.** Some causes cannot fix themselves, so the client stops and says what to do:
  - the name belongs to another account (another person, or another device's key) on that server: choose another name in Settings;
  - the server's identity key does not match the pinned one (expected after a server reset or reinstall): **Trust the new key** replaces the pin, saves the config, and reconnects;
  - the client and server speak different protocol versions;
  - the display name is too short or too long, or the identity key in the config is corrupt.

Client config keys (`config.json`):

| Key | Purpose |
| --- | --- |
| `display_name` | The nickname sent to every server. A server's account belongs to the identity key: a new key gets an account under this name, and a new name renames that key's account (see Display names) |
| `private_key`, `public_key` | The client's Ed25519 identity, generated on first start. Keep the file private (it is written with mode `0600`) |
| `servers[]` | Configured servers: `id`, `name`, `short_name` (rail label), `host`, `port` |
| `servers[].pinned_server_public_key`, `servers[].pinned_server_fingerprint` | The server identity pinned on first connect. Cleared when the server's address changes; replaced by **Trust the new key** |

### Development Environment

Development runs in [podman](https://podman.io/) containers, so the host needs only podman (`sudo dnf install podman` on Fedora, `sudo apt install podman` on Debian/Ubuntu). `./dev.sh` is the single entry point. Run `./dev.sh help` for the full command list.

Every container uses the dev image built from `dev/Containerfile`: Fedora 44, the system libraries HayChat links against, and the Odin toolchain and shared libraries at the commits pinned in `dev/bootstrap-odin.sh`. The image tag is a hash of those inputs. Changing a package or a pin produces a new tag, and the next `./dev.sh` command rebuilds the image (the first build takes a few minutes). Containers never see the repository directly. Each gets a snapshot of the working tree: tracked files, including uncommitted edits, plus untracked files that `.gitignore` does not exclude. Local leftovers such as `logs/`, `storage/`, built binaries, and your `~/.config/haychat` never reach a container, and no command touches them.

#### Checks

| Command | What it runs |
| --- | --- |
| `./dev.sh check` | `./check.sh`: `odin check` for the server and for the client on Linux and Windows, then every test suite with leak detection (a test fails on any leak or bad free) |
| `./dev.sh live` | `dev/live-proof.sh`: builds and starts the server against a throwaway PostgreSQL, checks that it created `#general`, loads the `server/sql/auth_bootstrap.sql` fixture, then runs the live startup auth proof. `--all` adds the two-client room chat and direct message proofs, the harness and GUI smoke tests, and the server SQL proof |
| `./dev.sh live --harness` | Only `dev/harness-smoke.sh` against the live server: headless clients connect, list rooms, chat, exchange a direct message, and (made admin with `deploy/sql/make-admin.sql`) create, rename, and delete a room (see [docs/testing-harness.md](docs/testing-harness.md)). `--all` runs it too |
| `./dev.sh live --ui` | Only `dev/ui-smoke.sh` against the live server: the real client window, on SDL's offscreen driver, is driven by `--ui-script` to chat, exchange a direct message with a headless client, and create a room as an admin, taking screenshots (set `HAYCHAT_DEV_UI_SCREENSHOTS=DIR` to keep them; see [docs/testing-harness.md](docs/testing-harness.md#gui-automation)). `--all` runs it too |
| `./dev.sh live --sql` | Only the server SQL proof: database-backed server tests (gated on `HAYCHAT_DATABASE_SQL_TEST=1`) that run the direct message statements against the throwaway PostgreSQL. `--all` runs it too |
| `./dev.sh ci` | `check`, then `live --all`: the same steps Forgejo CI runs |

Each run gets fresh containers. `live` and `ci` also get a fresh PostgreSQL in a tmpfs, so live test users never pile up. The throwaway pod publishes no ports, so it runs alongside the dev environment or a host server without conflicts.

#### Dev Environment

`./dev.sh up` starts the pod `haychat-dev`: PostgreSQL 17 and a server built from your working tree. The containers share the pod's network and reach each other on `127.0.0.1`. Clients connect on `localhost:12345/udp`, the only published port.

| Command | Purpose |
| --- | --- |
| `./dev.sh up` | Build the server and start the pod |
| `./dev.sh restart` | Rebuild the server from the working tree and restart it. A compile error leaves the running server up |
| `./dev.sh status` | Containers, ports, and the web admin token |
| `./dev.sh logs [-f]` | Server output |
| `./dev.sh admin [-X METHOD] PATH` | Call a web admin route with the token filled in, e.g. `./dev.sh admin /peers` |
| `./dev.sh seed` | Load the `server/sql/auth_bootstrap.sql` fixture (see Seeded test identities) |
| `./dev.sh psql [ARGS...]` | psql on the dev database |
| `./dev.sh client [PROFILE]` | Build the client and open its window on your Wayland or X11 display. Each profile has its own config and identity key. A new profile's display name is the profile name and its server is the dev server, so two profiles are two users. Profiles created before the first-run screen existed have no server: enter `localhost` once on that screen |
| `./dev.sh key [PROFILE]` | Print a profile's public key, for `HAYCHAT_ADMIN_PUBLIC_KEY` |
| `./dev.sh down` | Remove the pod. The database, server state, and client profiles are kept in volumes |
| `./dev.sh reset` | `down`, then delete those volumes. The next `up` starts with an empty database and a new server identity key |
| `./dev.sh shell` | Interactive shell in the dev image with the repository mounted read-write at `/src`, for ad-hoc `odin` commands |
| `./dev.sh image [--pull]` | Rebuild the dev image; `--pull` also refreshes the Fedora base image |

The server keeps its logs, storage, identity key, and web admin token in the `haychat-dev-state` volume, and PostgreSQL keeps its data in `haychat-dev-pgdata`. Client profiles live in `haychat-dev-client-<profile>` volumes. A client running on the host (`odin run client`) also reaches the dev server, at its default `localhost:12345`.

The server's web admin uses `core:nbio`, which needs io_uring on Linux. Podman's default seccomp profile blocks io_uring, and so does the SELinux `container_t` policy on SELinux hosts. Containers that run the server therefore use podman's default seccomp profile plus the three io_uring syscalls (generated under `$XDG_RUNTIME_DIR/haychat-dev/`), and run without SELinux confinement. They remain rootless.

`./dev.sh` reads these environment variables:

- `HAYCHAT_DEV_PORT`: host UDP port published for client connections (default `12345`)
- `HAYCHAT_DEV_ENV_FILE`: server overrides file (default `.env`, see below)
- `HAYCHAT_DEV_POSTGRES_IMAGE`: PostgreSQL image (default `docker.io/library/postgres:17`)
- `HAYCHAT_DEV_SECCOMP`: seccomp profile for containers that run the server, replacing the generated one (for example `unconfined`)
- `HAYCHAT_SERVER_READY_TIMEOUT_SECS`: how long to wait for the server to report readiness. `./dev.sh up` and `restart` default to `120`; `dev/live-proof.sh` defaults to `60`, and `./dev.sh live` and `ci` pass the variable through to it when it is set

#### Without Containers

`./check.sh` and `dev/live-proof.sh` also run directly on a host that has `odin` on `PATH`. On Fedora 44, `sudo dev/install-packages.sh` installs the system packages and `dev/bootstrap-odin.sh [odin_root]` builds the pinned Odin toolchain and shared libraries. `dev/live-proof.sh` expects a PostgreSQL it can reach through `HAYCHAT_DATABASE_*`, and that role must be able to create, alter, and drop the server-owned schema in `public`.

### Client Dependencies

The client draws its own immediate-mode UI with `vendor:sdl3` (windowing, input, and the 2D renderer) and `vendor:sdl3/ttf` (text shaping and layout), both from Odin's vendor collection. No other GUI library is needed.

- Linux: the dev image includes SDL3 and SDL3_ttf. On a host, install the development packages (`SDL3-devel SDL3_ttf-devel` on Fedora, `libsdl3-dev libsdl3-ttf-dev` on Ubuntu 25.04+/Debian 13+).
- Windows: Odin's vendor collection ships the import libraries. To run the client, copy `SDL3.dll` from `%ODIN_ROOT%\vendor\sdl3\` and `SDL3_ttf.dll` from `%ODIN_ROOT%\vendor\sdl3\ttf\` next to `client.exe`. `./check.sh` type-checks the Windows client from Linux, but CI does not build or run it on Windows.

The UI fonts (Inter, under the SIL Open Font License, and Twemoji, under CC-BY 4.0) are embedded into the client binary from `client/assets/fonts/`, where their license files live.

### Server Configuration

The server reads its configuration from environment variables. In the dev pod, `./dev.sh` sets the database, listen, and path settings itself. Every other key can be set in `.env` (`cp .env.example .env`), which `./dev.sh up` and `./dev.sh restart` pass to the server. Running `odin run server` directly reads the same keys from the process environment. When startup fails (invalid configuration, an unreachable or incompatible database, or a service thread that cannot start), the server prints a line starting with `[Startup]` and exits with status 1, so a service manager's `Restart=on-failure` and scripts can tell a failed start from a clean shutdown, which exits 0.

Database (set by `./dev.sh` in the pod):

- `HAYCHAT_DATABASE_URL` (default `localhost`)
- `HAYCHAT_DATABASE_PORT` (default `5432`)
- `HAYCHAT_DATABASE_USER` (default `haychat`)
- `HAYCHAT_DATABASE_PASS` (default `haychat`)
- `HAYCHAT_DATABASE_NAME` (default `haychat`)

Network and paths (set by `./dev.sh` in the pod):

- `HAYCHAT_LISTEN_ADDR` (default `0.0.0.0`)
- `HAYCHAT_LISTEN_PORT` (default `12345`)
- `HAYCHAT_WEB_ADMIN_PORT` (default `8080`)
- `HAYCHAT_LOG_DIR` (default `./logs`)
- `HAYCHAT_FILE_STORAGE_PATH` (default `./storage`)
- `HAYCHAT_SERVER_IDENTITY_FILE` (default `$HAYCHAT_FILE_STORAGE_PATH/server_identity.json`)

Paths are resolved relative to the server's working directory.

Runtime (configurable in `.env`):

- `HAYCHAT_LOG_LEVEL` (default `info`)
- `HAYCHAT_MAX_RESTARTS` (default `5`)
- `HAYCHAT_RESTART_BACKOFF_MIN` (seconds, default `0.1`)
- `HAYCHAT_RESTART_BACKOFF_MAX` (seconds, default `10.0`)
- `HAYCHAT_MAX_NETWORK_THREADS` (default `4`): ENet peer capacity, 16 connections per unit (64 by default). It no longer starts threads; the network worker pool it once sized was removed.
- `HAYCHAT_MAX_FILE_SIZE` (bytes, default `10485760`)
- `HAYCHAT_MAX_STORAGE_CAPACITY` (bytes, default `1073741824`)
- `HAYCHAT_SERVER_PRIVATE_KEY`, `HAYCHAT_SERVER_PUBLIC_KEY`: fixed server identity. When both are unset, the server loads or generates `HAYCHAT_SERVER_IDENTITY_FILE`.
- `HAYCHAT_ADMIN_PUBLIC_KEY`: hex Ed25519 client public key allowed to claim keyless accounts that hold server roles, such as the seeded `admin`. Without it, those accounts cannot be claimed over the network. Ordinary keyless accounts are still bound to the first key that connects with their nickname. `./dev.sh key [PROFILE]` prints a dev client profile's key.
- `HAYCHAT_WEB_ADMIN_TOKEN`: bearer token (at least 32 characters) for the protected web admin routes. When unset, the server generates one and stores it at `$HAYCHAT_FILE_STORAGE_PATH/web_admin_token` with `0600` permissions.

The server owns table creation and validation. It creates or reconciles its schema before it reports readiness; on an incompatible unreleased schema, it rebuilds the HayChat tables transactionally. The configured role must be able to create, alter, and drop objects in `public`. When the `rooms` table is empty, startup then creates `#general` (see Rooms). `server/sql/auth_bootstrap.sql` is a test-data fixture only and is not used by normal startup.

### Web Admin

The web admin listens on `127.0.0.1` only, so in the dev pod it is reachable from inside the pod but not from the host. `GET /status` is an unauthenticated health probe. `GET /peers`, `GET /logs`, `POST /shutdown`, and `POST /restart` require the bearer token. `./dev.sh admin` calls a route from inside the pod with the token filled in:

```sh
./dev.sh admin /peers
./dev.sh admin -X POST /restart
```

For a server running directly on the host:

```sh
curl -H "Authorization: Bearer $(cat storage/web_admin_token)" http://localhost:8080/peers
```

### Typical Workflow

1. `./dev.sh up` to start PostgreSQL and the server.
2. Optionally, `./dev.sh seed` to load the fixture users. You only need it for the `admin` account; the server creates `#general` by itself.
3. To connect as `admin`: run `./dev.sh client admin` once to create the profile (it cannot claim `admin` yet) and close it. Put the output of `./dev.sh key admin` in `.env` as `HAYCHAT_ADMIN_PUBLIC_KEY=...`, run `./dev.sh restart`, then run `./dev.sh client admin` again.
4. Open more clients with `./dev.sh client alice`, `./dev.sh client bob`, and so on. A profile's display name is its profile name, so each profile is a distinct user.
5. To manage rooms, connect as `admin` (step 3): it holds the admin role, so its sidebar shows **+ New room** and each room header **Edit room** (see Rooms). To make another profile an admin instead, run `./dev.sh psql -v owner=alice <deploy/sql/make-admin.sql` after it connected once, then reopen that client.
6. After code changes, `./dev.sh restart` for the server and reopen clients to rebuild them.
7. Before pushing, run `./dev.sh ci`.
8. `./dev.sh down` when done, or `./dev.sh reset` to start over.

Seeded test identities:

- `admin` resolves to user ID `1` and holds the `admin` server role. Set `HAYCHAT_ADMIN_PUBLIC_KEY` to your client's public key before connecting as `admin`.
- `haypeer` resolves to user ID `2` and is bound to the first client key that connects with that nickname.
- `#general` is room ID `1`. The server creates it; loading the fixture restores its name and description and makes every existing account a member of it.

### Rooms

Rooms are open: every account is a member of every room. A nickname that connects for the first time joins every existing room, and a new room includes every account, so testers can chat as soon as they connect. Membership is still stored per account in `room_members`, which the server checks for every send and history request; that is where private rooms will plug in.

Admins manage rooms from the client. An admin is an account holding the `admin` server role; every other account sees no room controls. In the selected server's sidebar, the **Channels** header shows **+ New room**, which opens a form in the main pane (name of 1 to 64 bytes, a leading `#` is dropped; optional description of up to 256 bytes; **Create** or **Cancel**). The server adds every account to the new room, every connected client refreshes its room list, and the admin's client selects the new room. A room's header shows **Edit room**, which opens the same form filled in, with **Save**, **Cancel**, and **Delete room**; delete asks for a second click (**Confirm delete**) and removes the room with its history. Clients whose selected room was deleted move to `#general`, or to the first room when `#general` is gone. Deleting `#general` itself is allowed: the form warns that the server only recreates it on its next start when no rooms are left. The form closes when its room is renamed or deleted by another admin, and shows the server's answer when it refuses (for example a duplicate name, or "Admin permission required" when the role was revoked). Rooms are open, so the client has no member management: `ClientAddRoomMember` and `ClientRemoveRoomMember` stay in the protocol for private rooms later, and the client never sends them.

To become an admin, connect once with the display name that should own the server, then run `deploy/sql/make-admin.sql` against the database (`psql -v owner=NICKNAME -f deploy/sql/make-admin.sql`, see deploy/README.md "First-Time Setup"). In the dev pod, either pipe it into `./dev.sh psql -v owner=NICKNAME`, or `./dev.sh seed` and claim the fixture's `admin` account with `HAYCHAT_ADMIN_PUBLIC_KEY` (see Typical Workflow). The server sends the flag in `ServerAuthSuccess.isAdmin` when a session signs in, so a client made admin while connected sees the controls after its next connection (restart it, or press **Retry now** after a disconnect); the server checks the role again for every room request either way. The flag arrived with protocol version 8: clients and servers must be rebuilt together, and older ones refuse each other with "Unsupported protocol version".

On startup, a server whose `rooms` table is empty creates `#general` ("General discussion", room ID `1` on a new database) and makes every existing account a member, so a fresh server is ready to chat with no fixture. It logs `Created default room #general` when it does. Once any room exists it creates nothing, so an admin who renames or deletes `#general` keeps that change across restarts, as long as another room remains. A room the server creates has no creator (`rooms.created_by_user_id` is `NULL`); servers that ran protocol 7 drop that column's `NOT NULL` in place, keeping their data. Admins create further rooms from the client (above). Only accounts created after this change join rooms automatically: an account that already existed keeps the memberships it had, so an admin's `ClientRemoveRoomMember` lasts across reconnects.

#### Display names

An account is its client identity key; the nickname is only its current name. The first time a key connects, the server creates an account under the client's display name (or, for a keyless fixture account such as `haypeer`, binds the key to it). When the same key later connects with a different display name, the server renames that account in place: same user ID, same rooms, same direct messages. The rename succeeds only while no other account holds the new name; otherwise the login is refused and the client says the name is already in use. A renamed account does not join any rooms it was not already in. Connected users learn the new name at once, through the same online notice used for presence, and their clients update the Members and Direct Messages lists. Messages a client has already loaded keep the name they were sent with until it fetches that history again (on its next start, for example): fetched history shows each sender's current name, because the server reads it when the history is requested. The server logs `[Main] User N renamed from "old-name" on peer P` for each rename. The old name is free for anyone after a rename.

#### Direct messages

Any two accounts on a server can message each other directly. Direct messages belong to that one server: they are stored in its `direct_messages` table, survive restarts, and are paged like room history. Like room chat, they are encrypted in transit to the server but are not end-to-end encrypted, so the server and its operator can read them. A sent message is delivered to every connected session of both the sender and the recipient. The server also lists every account with an online flag (online while at least one of its sessions is authenticated) and tells connected sessions when an account comes online or goes offline. Direct messages arrived with protocol version 7; clients and servers on older versions refuse each other with "Unsupported protocol version".

In the client, the selected server's sidebar lists its channels, then **Direct Messages** (recent conversations, newest first) and **Members** (every other account, online first, then alphabetical). A green dot marks an account that is online. Clicking a conversation or a member opens the conversation in the main pane, with the person's name and online state in the header, the transcript (your own messages are labelled "You"), **Load older messages** while older ones exist, and a composer like the room one; clicking a channel goes back to it. A message that arrives for a conversation that is not open moves it to the top of **Direct Messages** and shows an unread count until you open it. The server keeps no read state, so unread counts start at zero each time the client starts. Conversations belong to one server; the rail has no separate direct-message button.

### Deployment

[deploy/README.md](deploy/README.md) covers running HayChat for real users: the production server image (`deploy/Containerfile`, a multi-stage build that uses the same package script and Odin pins as the dev image), systemd quadlet units that run it next to PostgreSQL (`deploy/quadlet/`), the io_uring container settings, first-time setup (`deploy/sql/make-admin.sql` gives your account the admin role), the firewall, backups, and upgrades.

| Command | Purpose |
| --- | --- |
| `./dev.sh release-image` | Build the production server image as `localhost/haychat-server:dev` |
| `./dev.sh release-image --smoke` | Also run it against a throwaway PostgreSQL, check that a headless client connects and sees `#general`, and run `deploy/sql/make-admin.sql` |
| `deploy/release-artifacts.sh VERSION OUT_DIR [--windows]` | Build the release archives (server binary, Linux client, cross-compiled Windows client) inside `./dev.sh shell` |

`.forgejo/workflows/release.yml` runs on tags `v*`: it builds the archives and the image, pushes the image to the repository's container registry, and publishes a Forgejo release (see deploy/README.md "Release Builds").

### Continuous Integration

HayChat is developed on Forgejo, and `.forgejo/workflows/ci.yml` runs on every push to `main` and on every pull request. The Linux runner uses a Fedora 44 job container with a PostgreSQL 17 service. It runs `dev/install-packages.sh`, `dev/bootstrap-odin.sh`, `./check.sh`, and `dev/live-proof.sh --all`, the same steps as `./dev.sh ci`. The Odin toolchain is cached under `/opt/Odin` when the runner's cache is enabled; the cache is saved only after a successful run.

The live proof needs io_uring in the job container (see Dev Environment), which takes two changes on a podman-backed runner host. Both apply to every container that runner starts.

1. Seccomp: make the io_uring profile podman's default. forgejo-runner sends `--security-opt seccomp=FILE` as inline JSON, Docker style, which podman's Docker-compatible API rejects ("opening seccomp profile failed ... file name too long"). Instead, generate the profile from the host's own podman default and point `containers.conf` at it. Use `/etc/containers/containers.conf.d/` when the runner talks to rootful podman, or `~/.config/containers/containers.conf.d/` of the runner's user for rootless podman:

   ```sh
   ./dev.sh seccomp-profile /etc/forgejo-runner/seccomp-io-uring.json
   ```

   ```toml
   # containers.conf.d/50-io-uring.conf
   [containers]
   seccomp_profile = "/etc/forgejo-runner/seccomp-io-uring.json"
   ```

   Restart the podman API service (`podman.socket` / `podman.service`) afterwards.

2. SELinux (only on SELinux hosts): forgejo-runner ignores `--security-opt` in a workflow's `container.options`, so set it in the runner's `config.yml` and restart the runner:

   ```yaml
   container:
     options: --security-opt label=disable
   ```

`dev/live-proof.sh` prints the sandbox it got before starting the server. A working runner shows `seccomp=filtered selinux=...spc_t... io_uring_disabled=0`. `container_t` means step 2 is missing; seccomp with io_uring still blocked shows up as the web admin's `acquire_err == nil` assertion.

### Known Limitations

- Private rooms are not implemented. Every account joins every room (see Rooms), so the client has no member management; admins create, rename, and delete rooms from the client.
- The admin flag is read when a session signs in: granting or revoking the role takes effect in the client's controls on its next connection (the server enforces it at once).
- Account registration (`ClientRegister`) is not implemented; accounts are created when a new identity key first connects.
- A display name change renames the same account rather than making a new one, and only through the client's own key: there is no way to move an account to another device or key, and no admin rename. Messages a client has already loaded keep the name they were sent with (see Display names).
- Messages are not end-to-end encrypted (see Features).
- Direct messages have no read receipts or server-side unread state; the client counts unread messages only while it is running.
- The server has no schema migrations: a server version with an incompatible schema rebuilds the database empty (see deploy/README.md "Upgrades").

## License

HayChat is licensed under the AGPLv3 License. See the [LICENSE](LICENSE) file for more information.

Remember that if you distribute modified versions of the software, you must also distribute the source code and include the same license. Always ensure you have the right to use and distribute any code you contribute under the AGPLv3 License.

If a user wants to use HayChat in a commercial product, they would need to comply with the AGPLv3 License terms, which may require them to release their own source code under the same license if they distribute the software. This is a key aspect of the AGPLv3 License, which promotes open-source software and ensures that derivative works also remain open-source.

### Modding

If you sell a mod publicly, it must be dynamically linked. This means that you can create a mod that interacts with HayChat, but you cannot include the entire HayChat codebase in your mod. Instead, your mod should be a separate module that communicates with HayChat through defined interfaces or APIs. This allows for greater flexibility and ensures that the core HayChat code remains open and accessible to the community while still allowing for creative modifications and extensions.

## Contributing

Contributions are welcome! Please read the contributing guidelines in the `CONTRIBUTING.md` file for more information on how to contribute to the project.

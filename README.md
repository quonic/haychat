# HayChat

![HayChat Logo](assets/icon.png)

HayChat is a self-hosted alternative to Discord. It features encrypted client-server transport, a responsive user interface, and a modular architecture for easy extensibility.

> [!IMPORTANT]
> HayChat is currently in early development and is not yet ready for production use. The project is open-source and welcomes contributions from the community.

## Features

- Encrypted transport between client and server: Ed25519 identities, X25519 key exchange, and XChaCha20-Poly1305 packets, with the server key pinned on first connect. The server decrypts messages and stores them unencrypted in its PostgreSQL database; end-to-end encryption is not implemented yet.
- Real-time messaging with low latency
- User-friendly interface with customizable themes
- Support for server chat in shared rooms, with direct messages planned for a later release
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

On Linux, the client stores its config at `XDG_CONFIG_HOME/haychat/config.json`, defaulting to `$HOME/.config/haychat/config.json` when `XDG_CONFIG_HOME` is unset. Startup also migrates the original historical malformed path formula `$HOME$XDG_CONFIG_HOME/haychat/config.json`, which means older installs are recovered from either the default `$HOME$HOME/.config/haychat/config.json` shape or a custom `XDG_CONFIG_HOME` variant if that file still exists.

### Development Environment

Development runs in [podman](https://podman.io/) containers, so the host needs only podman (`sudo dnf install podman` on Fedora, `sudo apt install podman` on Debian/Ubuntu). `./dev.sh` is the single entry point. Run `./dev.sh help` for the full command list.

Every container uses the dev image built from `dev/Containerfile`: Fedora 44, the system libraries HayChat links against, and the Odin toolchain and shared libraries at the commits pinned in `dev/bootstrap-odin.sh`. The image tag is a hash of those inputs. Changing a package or a pin produces a new tag, and the next `./dev.sh` command rebuilds the image (the first build takes a few minutes). Containers never see the repository directly. Each gets a snapshot of the working tree: tracked files, including uncommitted edits, plus untracked files that `.gitignore` does not exclude. Local leftovers such as `logs/`, `storage/`, built binaries, and your `~/.config/haychat` never reach a container, and no command touches them.

#### Checks

| Command | What it runs |
| --- | --- |
| `./dev.sh check` | `./check.sh`: `odin check` for the server and for the client on Linux and Windows, then every test suite with leak detection (a test fails on any leak or bad free) |
| `./dev.sh live` | `dev/live-proof.sh`: builds and starts the server against a throwaway PostgreSQL, then runs the live startup auth proof. `--all` adds the two-client chat proof (see Known Limitations) |
| `./dev.sh ci` | `check`, then `live`: the same steps Forgejo CI runs |

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
| `./dev.sh client [PROFILE]` | Build the client and open its window on your Wayland or X11 display. Each profile has its own config and identity key, and a new profile's display name is the profile name, so two profiles are two users |
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
- `HAYCHAT_SERVER_READY_TIMEOUT_SECS`: how long to wait for the server to report readiness (default `120` for `./dev.sh`, `60` for `dev/live-proof.sh`)

#### Without Containers

`./check.sh` and `dev/live-proof.sh` also run directly on a host that has `odin` on `PATH`. On Fedora 44, `sudo dev/install-packages.sh` installs the system packages and `dev/bootstrap-odin.sh [odin_root]` builds the pinned Odin toolchain and shared libraries. `dev/live-proof.sh` expects a PostgreSQL it can reach through `HAYCHAT_DATABASE_*`, and that role must be able to create, alter, and drop the server-owned schema in `public`.

### Client Dependencies

The client draws its own immediate-mode UI with `vendor:sdl3` (windowing, input, and the 2D renderer) and `vendor:sdl3/ttf` (text shaping and layout), both from Odin's vendor collection. No other GUI library is needed.

- Linux: the dev image includes SDL3 and SDL3_ttf. On a host, install the development packages (`SDL3-devel SDL3_ttf-devel` on Fedora, `libsdl3-dev libsdl3-ttf-dev` on Ubuntu 25.04+/Debian 13+).
- Windows: Odin's vendor collection ships the import libraries. To run the client, copy `SDL3.dll` from `%ODIN_ROOT%\vendor\sdl3\` and `SDL3_ttf.dll` from `%ODIN_ROOT%\vendor\sdl3\ttf\` next to `client.exe`. `./check.sh` type-checks the Windows client from Linux, but CI does not build or run it on Windows.

The UI fonts (Inter, under the SIL Open Font License, and Twemoji, under CC-BY 4.0) are embedded into the client binary from `client/assets/fonts/`, where their license files live.

### Server Configuration

The server reads its configuration from environment variables. In the dev pod, `./dev.sh` sets the database, listen, and path settings itself. Every other key can be set in `.env` (`cp .env.example .env`), which `./dev.sh up` and `./dev.sh restart` pass to the server. Running `odin run server` directly reads the same keys from the process environment.

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
- `HAYCHAT_MAX_NETWORK_THREADS` (default `4`)
- `HAYCHAT_MAX_FILE_SIZE` (bytes, default `10485760`)
- `HAYCHAT_MAX_STORAGE_CAPACITY` (bytes, default `1073741824`)
- `HAYCHAT_SERVER_PRIVATE_KEY`, `HAYCHAT_SERVER_PUBLIC_KEY`: fixed server identity. When both are unset, the server loads or generates `HAYCHAT_SERVER_IDENTITY_FILE`.
- `HAYCHAT_ADMIN_PUBLIC_KEY`: hex Ed25519 client public key allowed to claim keyless accounts that hold server roles, such as the seeded `admin`. Without it, those accounts cannot be claimed over the network. Ordinary keyless accounts are still bound to the first key that connects with their nickname. `./dev.sh key [PROFILE]` prints a dev client profile's key.
- `HAYCHAT_WEB_ADMIN_TOKEN`: bearer token (at least 32 characters) for the protected web admin routes. When unset, the server generates one and stores it at `$HAYCHAT_FILE_STORAGE_PATH/web_admin_token` with `0600` permissions.

The server owns table creation and validation. It creates or reconciles its schema before it reports readiness; on an incompatible unreleased schema, it rebuilds the HayChat tables transactionally. The configured role must be able to create, alter, and drop objects in `public`. `server/sql/auth_bootstrap.sql` is a test-data fixture only and is not used by normal startup.

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
2. `./dev.sh seed` to load the fixture users and the `#general` room.
3. To connect as `admin`: run `./dev.sh client admin` once to create the profile (it cannot claim `admin` yet) and close it. Put the output of `./dev.sh key admin` in `.env` as `HAYCHAT_ADMIN_PUBLIC_KEY=...`, run `./dev.sh restart`, then run `./dev.sh client admin` again.
4. Open more clients with `./dev.sh client alice`, `./dev.sh client bob`, and so on. A profile's display name is its profile name, so each profile is a distinct user.
5. After code changes, `./dev.sh restart` for the server and reopen clients to rebuild them.
6. Before pushing, run `./dev.sh ci`.
7. `./dev.sh down` when done, or `./dev.sh reset` to start over.

Seeded test identities:

- `admin` resolves to user ID `1` and holds the `admin` server role. Set `HAYCHAT_ADMIN_PUBLIC_KEY` to your client's public key before connecting as `admin`.
- `haypeer` resolves to user ID `2` and is bound to the first client key that connects with that nickname.

### Continuous Integration

HayChat is developed on Forgejo, and `.forgejo/workflows/ci.yml` runs on every push to `main` and on every pull request. The Linux runner uses a Fedora 44 job container with a PostgreSQL 17 service. It runs `dev/install-packages.sh`, `dev/bootstrap-odin.sh`, `./check.sh`, and `dev/live-proof.sh`, the same steps as `./dev.sh ci`. The job container runs with `seccomp=unconfined` and `label=disable` because the runner host has no copy of the narrower io_uring profile.

### Known Limitations

- New accounts are not added to any room. The seed fixture creates the `general` room with only `admin` as a member, so other users cannot chat until an admin adds them (`ClientAddRoomMember`). The two-client live chat proof (`./dev.sh live --all`) fails for the same reason, so CI runs only the startup auth proof.
- Account registration (`ClientRegister`) is not implemented; accounts are created when a new nickname first connects.
- Messages are not end-to-end encrypted (see Features).

## License

HayChat is licensed under the AGPLv3 License. See the [LICENSE](LICENSE) file for more information.

Remember that if you distribute modified versions of the software, you must also distribute the source code and include the same license. Always ensure you have the right to use and distribute any code you contribute under the AGPLv3 License.

If a user wants to use HayChat in a commercial product, they would need to comply with the AGPLv3 License terms, which may require them to release their own source code under the same license if they distribute the software. This is a key aspect of the AGPLv3 License, which promotes open-source software and ensures that derivative works also remain open-source.

### Modding

If you sell a mod publicly, it must be dynamically linked. This means that you can create a mod that interacts with HayChat, but you cannot include the entire HayChat codebase in your mod. Instead, your mod should be a separate module that communicates with HayChat through defined interfaces or APIs. This allows for greater flexibility and ensures that the core HayChat code remains open and accessible to the community while still allowing for creative modifications and extensions.

## Contributing

Contributions are welcome! Please read the contributing guidelines in the `CONTRIBUTING.md` file for more information on how to contribute to the project.

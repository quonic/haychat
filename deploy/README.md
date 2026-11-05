# Deploying HayChat

<!-- This file also ships as DEPLOY.md in the server release archive, so links are absolute. -->

This guide is for the person who runs a HayChat server for testers. It covers the production
server image, running it with PostgreSQL under podman, first-time setup, backups, upgrades,
and the release builds that produce the image and the client downloads. Testers need only
[docs/tester-guide.md](https://git.spyingwind.com/jim/haychat/src/branch/main/docs/tester-guide.md).

> [!WARNING]
> HayChat is unreleased. When a new server version changes the database schema, the server
> **drops and rebuilds its tables on startup, deleting every account, room, and message**.
> There are no migrations yet. Take a backup before every upgrade (see [Upgrades](#upgrades))
> and tell testers their history may be wiped.

## What Is Here

| File | Purpose |
| --- | --- |
| `deploy/Containerfile` | Multi-stage build of the server image: Fedora 44 with the pinned Odin toolchain builds the server; a `fedora-minimal:44` stage runs it |
| `deploy/quadlet/` | systemd units (podman quadlet): `haychat.pod`, `haychat-db.container`, `haychat-server.container` |
| `deploy/sql/make-admin.sql` | Gives one existing account the admin role |
| `deploy/release-artifacts.sh` | Builds the server binary and client archives for a release |
| `deploy/client-README-*.txt` | The `README.txt` shipped in each client archive |
| `.forgejo/workflows/release.yml` | Release builds on Forgejo (see [Release Builds](#release-builds)) |
| `.containerignore` | Limits the image's build context to the files it needs |

## The Server Image

Releases push the image to the repository's container registry:

```sh
podman pull git.spyingwind.com/jim/haychat/server:v0.1.0   # or :latest
```

To build it yourself from a checkout (the build context must be the repository root):

```sh
podman build -f deploy/Containerfile -t haychat-server .
./dev.sh release-image            # the same, tagged localhost/haychat-server:dev
./dev.sh release-image --smoke    # also run it against a throwaway database and connect a client
```

The first build compiles the pinned Odin toolchain and takes several minutes; later builds
reuse that layer until `dev/install-packages.sh` or `dev/bootstrap-odin.sh` changes. The build
stage uses those two scripts, so the image is built with exactly the packages and Odin commits
the dev image and CI use.

| Property | Value |
| --- | --- |
| Base | `registry.fedoraproject.org/fedora-minimal:44`, about 150 MB in total |
| Runtime packages | `libpq` and `enet` (the binary links `libpq.so.5`, `libenet.so.7`, and glibc); `curl` comes with the base image |
| Entrypoint | `/usr/local/bin/haychat-server` |
| User | `haychat`, UID/GID `10001`, not root |
| Working directory | `/var/lib/haychat` |
| Volumes | `/var/lib/haychat/logs` (`HAYCHAT_LOG_DIR`) and `/var/lib/haychat/storage` (`HAYCHAT_FILE_STORAGE_PATH`: server identity key, web admin token) |
| Port | `12345/udp` (clients) |
| Stop signal | `SIGINT`, the server's graceful shutdown; it stops its worker threads and exits 0 |
| Also included | `/usr/share/haychat/sql/` (`make-admin.sql`, `auth_bootstrap.sql`) and the licence |

The image sets `HAYCHAT_LISTEN_ADDR=0.0.0.0`, `HAYCHAT_LISTEN_PORT=12345`,
`HAYCHAT_WEB_ADMIN_PORT=8080`, and the three path variables (`HAYCHAT_LOG_DIR`,
`HAYCHAT_FILE_STORAGE_PATH`, `HAYCHAT_SERVER_IDENTITY_FILE`) to match the volumes.

The server writes its log to stdout (read it with `journalctl` or `podman logs`).
`HAYCHAT_LOG_DIR` is created at startup and reserved for log files.

## io_uring: Required Container Settings

The server's web admin runs on `core:nbio`, which uses io_uring on Linux. Two default
container restrictions block io_uring, and the server fails to start with either in place:

1. **Podman's default seccomp profile** blocks the `io_uring_setup`, `io_uring_enter`, and
   `io_uring_register` syscalls. Write podman's own default profile plus those three syscalls
   with:

   ```sh
   ./dev.sh seccomp-profile /etc/haychat-server/seccomp-io-uring.json
   ```

   and run the server with `--security-opt seccomp=/etc/haychat-server/seccomp-io-uring.json`.
   The rest of the default filter stays in place. (`seccomp=unconfined` also works but drops
   the whole filter.)
2. **SELinux** (Fedora, RHEL, and other SELinux hosts): the `container_t` policy denies
   io_uring too. Run the server with `--security-opt label=disable`.

The container stays rootless-compatible and unprivileged. Hosts that set the sysctl
`kernel.io_uring_disabled=2` cannot run the server at all.

## Running With Quadlet (Recommended)

The units in `deploy/quadlet/` run PostgreSQL 17 and the server as systemd services in one
pod. The two containers share the pod's network and reach each other on `127.0.0.1`; the pod
publishes only UDP `12345`, so neither PostgreSQL nor the web admin is reachable from outside.

Quadlet rather than a `podman kube play` YAML: systemd restarts the services on failure and
starts them at boot, logs go to the journal, and the settings the server needs
(`SeccompProfile=`, `SecurityLabelDisable=`, `Secret=`, `RunInit=`) are plain quadlet keys
instead of Kubernetes annotations. The `.pod` unit needs **podman 5.0 or newer** (Fedora 40+,
RHEL 10, Debian 13, Ubuntu 25.04). On an older podman, use the commands in
[Running With Plain Podman](#running-with-plain-podman).

The steps below install a system service as root. For a rootless user service, use
`~/.config/containers/systemd/` instead of `/etc/containers/systemd/`,
`~/.config/haychat-server/` instead of `/etc/haychat-server/`, `systemctl --user`, and run
`loginctl enable-linger $USER` once so the services run while you are logged out. The units
find their config through `%E`, which systemd expands to `/etc` for system services and to
`~/.config` for user services.

1. Create the database password as a podman secret (both containers read it):

   ```sh
   openssl rand -base64 32 | tr -d '\n' | sudo podman secret create haychat-db-password -
   ```

2. Create the config directory, the io_uring seccomp profile, and the server's environment
   file (it must exist, even if empty):

   ```sh
   sudo mkdir -p /etc/haychat-server
   sudo ./dev.sh seccomp-profile /etc/haychat-server/seccomp-io-uring.json
   sudo install -m 0600 /dev/null /etc/haychat-server/server.env
   ```

   Put optional settings from [Environment Variables](#environment-variables) in
   `server.env`, one `KEY=VALUE` per line.

3. Install the units, choose the image tag, and start the pod:

   ```sh
   sudo cp deploy/quadlet/* /etc/containers/systemd/
   sudoedit /etc/containers/systemd/haychat-server.container   # Image=...:v0.1.0
   sudo systemctl daemon-reload
   sudo systemctl start haychat-pod.service
   ```

   `haychat-pod.service` starts both containers, and the `[Install]` sections start them at
   boot. Quadlet units are generated, so `systemctl enable` is neither needed nor possible.

4. Check it:

   ```sh
   sudo systemctl status haychat-server.service
   sudo journalctl -u haychat-server.service -f      # wait for "=== Server Running ==="
   sudo podman exec haychat-server curl -fsS http://127.0.0.1:8080/status
   ```

5. Open the firewall (see [Network](#network)) and continue with
   [First-Time Setup](#first-time-setup).

## Running With Plain Podman

The same setup by hand, useful for a first try or on podman 4:

```sh
openssl rand -base64 32 | tr -d '\n' | podman secret create haychat-db-password -
./dev.sh seccomp-profile "$HOME/.config/haychat-server/seccomp-io-uring.json"

podman pod create --name haychat -p 12345:12345/udp

podman run -d --pod haychat --name haychat-db \
	-e POSTGRES_USER=haychat -e POSTGRES_DB=haychat \
	--secret haychat-db-password,type=env,target=POSTGRES_PASSWORD \
	-v haychat-pgdata:/var/lib/postgresql/data \
	docker.io/library/postgres:17

podman run -d --pod haychat --name haychat-server --init \
	--security-opt label=disable \
	--security-opt seccomp="$HOME/.config/haychat-server/seccomp-io-uring.json" \
	-e HAYCHAT_DATABASE_URL=127.0.0.1 \
	--secret haychat-db-password,type=env,target=HAYCHAT_DATABASE_PASS \
	--env-file "$HOME/.config/haychat-server/server.env" \
	-v haychat-logs:/var/lib/haychat/logs \
	-v haychat-storage:/var/lib/haychat/storage \
	git.spyingwind.com/jim/haychat/server:v0.1.0

podman logs -f haychat-server       # "=== Server Running ===" means it is ready
```

Start PostgreSQL first: the server exits when it cannot reach the database at startup, and
it exits with status 0, so `--restart on-failure` would not bring it back. The quadlet units
start the server only after PostgreSQL reports healthy and restart it on any exit. `podman stop haychat-server` sends SIGINT
and waits for the graceful shutdown. Leave out `--env-file` when you have no overrides.

## Environment Variables

Every server setting is a `HAYCHAT_*` environment variable; [README.md "Server Configuration"](https://git.spyingwind.com/jim/haychat/src/branch/main/README.md#server-configuration)
lists them all with defaults, and [`.env.example`](https://git.spyingwind.com/jim/haychat/src/branch/main/.env.example) documents the optional ones. In this
deployment:

| Set by | Variables |
| --- | --- |
| The image | `HAYCHAT_LISTEN_ADDR`, `HAYCHAT_LISTEN_PORT`, `HAYCHAT_WEB_ADMIN_PORT`, `HAYCHAT_LOG_DIR`, `HAYCHAT_FILE_STORAGE_PATH`, `HAYCHAT_SERVER_IDENTITY_FILE` |
| The quadlet unit (or your `podman run`) | `HAYCHAT_DATABASE_URL=127.0.0.1`, `HAYCHAT_DATABASE_PORT`, `HAYCHAT_DATABASE_USER`, `HAYCHAT_DATABASE_NAME`, and `HAYCHAT_DATABASE_PASS` from the `haychat-db-password` secret |
| You, in `server.env` (all optional) | `HAYCHAT_LOG_LEVEL`, `HAYCHAT_MAX_RESTARTS`, `HAYCHAT_RESTART_BACKOFF_MIN`, `HAYCHAT_RESTART_BACKOFF_MAX`, `HAYCHAT_MAX_NETWORK_THREADS`, `HAYCHAT_MAX_FILE_SIZE`, `HAYCHAT_MAX_STORAGE_CAPACITY`, `HAYCHAT_ADMIN_PUBLIC_KEY`, `HAYCHAT_WEB_ADMIN_TOKEN`, `HAYCHAT_SERVER_PRIVATE_KEY`, `HAYCHAT_SERVER_PUBLIC_KEY` |

`server.env` holds secrets when you set the web admin token or a fixed server key, so keep it
at mode `0600`. To keep the server listening on another port inside the pod, set
`HAYCHAT_LISTEN_PORT` and change the pod's `PublishPort=` to match; changing only the left
side of `PublishPort=` is simpler.

## Network

Clients connect over **UDP port 12345** (or the host port you published). Open it on the
host firewall and on any cloud security group or router in front of the host:

```sh
sudo firewall-cmd --permanent --add-port=12345/udp && sudo firewall-cmd --reload   # firewalld
sudo ufw allow 12345/udp                                                           # ufw
```

Nothing else needs to be reachable. Give testers the host name (or public IP address) and the
port. The transport is encrypted (X25519 key exchange, XChaCha20-Poly1305) and every client
pins the server's identity key on its first connection, so no TLS certificate is involved.

## First-Time Setup

A fresh server is ready to chat: on its first start (whenever the `rooms` table is empty) it
creates `#general` as room 1, and every account joins every room. The log shows
`Created default room #general`. Testers only need the host and port.

Optionally, give your own account the admin role, which lets it create, rename, and delete
rooms and manage members through the protocol (the client has no UI for that yet):

1. Connect once with the client, using the display name that should own the server (for
   example `jim`). The server creates the account and binds the name to your client's key.
2. Run `deploy/sql/make-admin.sql` against the database:

   ```sh
   podman exec -i haychat-db psql -U haychat -d haychat -v owner=jim <deploy/sql/make-admin.sql
   ```

   Without a checkout, use the copy in the image:

   ```sh
   podman exec haychat-server cat /usr/share/haychat/sql/make-admin.sql \
   	| podman exec -i haychat-db psql -U haychat -d haychat -v owner=jim
   ```

   It prints `jim is an admin`. It fails without changing anything when no account has that
   name, and it is safe to run again. The equivalent statements, for typing into
   `podman exec -it haychat-db psql -U haychat -d haychat`:

   ```sql
   INSERT INTO server_roles (name) VALUES ('admin') ON CONFLICT DO NOTHING;
   INSERT INTO user_server_roles (user_id, role_id)
   	SELECT u.id, r.id FROM users u, server_roles r WHERE u.nickname = 'jim' AND r.name = 'admin'
   	ON CONFLICT DO NOTHING;
   ```

`server/sql/auth_bootstrap.sql` (also in the image) is the **test fixture** the dev
environment uses. It creates the accounts `admin` (ID 1) and `haypeer` (ID 2) and resets `#general`,
and it **deletes any account that holds ID 1 or 2 under another name**, with its messages.
Load it only into an empty database, and only if you want those accounts.

### Server Identity Key and HAYCHAT_ADMIN_PUBLIC_KEY

On first start the server generates its Ed25519 identity key in
`/var/lib/haychat/storage/server_identity.json` (the `haychat-storage` volume). Every client
pins it on its first connection. If the key changes (the volume is deleted, or the server is
reinstalled without a backup), every tester sees "The server's identity key does not match"
and must choose **Trust the new key**. Keep the key across upgrades, back it up with the
database, and tell testers when you did reset it on purpose. To manage the key outside the
volume, set `HAYCHAT_SERVER_PRIVATE_KEY` and `HAYCHAT_SERVER_PUBLIC_KEY` (hex) in
`server.env`.

`HAYCHAT_ADMIN_PUBLIC_KEY` is a client's hex Ed25519 public key (the `public_key` in its
`config.json`). The server lets only that key claim an account that holds a server role but
no key yet, such as the fixture's `admin`. With `make-admin.sql` your account is
already bound to your key, so you do not need it.

## Web Admin

The web admin listens on `127.0.0.1:8080` inside the pod only; it is never published. `GET
/status` is an unauthenticated health check (the quadlet unit uses it as `HealthCmd`). The
other routes (`/peers`, `/logs`, `POST /shutdown`, `POST /restart`) need the bearer token, which
the server generates in its storage volume unless `HAYCHAT_WEB_ADMIN_TOKEN` is set. Call them
from inside the container:

```sh
podman exec haychat-server sh -c \
	'curl -sS -H "Authorization: Bearer $(cat storage/web_admin_token)" http://127.0.0.1:8080/peers'
```

From another machine, SSH to the host and run the same command. Do not publish port 8080.

## Backups

Back up the database and the server's storage volume together:

```sh
podman exec haychat-db pg_dump -U haychat -d haychat -Fc >"haychat-$(date +%F).dump"
podman volume export haychat-storage >"haychat-storage-$(date +%F).tar"
```

The storage archive holds the server's private key and the web admin token: store it as
privately as the database dump. To restore into a fresh deployment, import the volume before
the first start (`podman volume create haychat-storage && podman volume import
haychat-storage FILE.tar`), start the pod, stop the server, and load the dump:

```sh
podman exec -i haychat-db pg_restore -U haychat -d haychat --clean --if-exists <FILE.dump
```

Then start the server again. A dump from an older schema is rebuilt (emptied) by a newer
server; see below.

## Upgrades

> [!CAUTION]
> While HayChat is unreleased, a server whose schema check fails **drops every HayChat
> table and recreates them empty**. Accounts, rooms, room history, and direct messages are
> gone. The server recreates `#general`; repeat [First-Time Setup](#first-time-setup) for the
> admin role. Testers keep their client
> identity, and the first client to reconnect with a given name gets that name again.

1. Read the release notes: they say whether the schema or the protocol version changed. A
   protocol change means every tester must update the client too; older clients show "This
   client and the server speak different protocol versions".
2. Take a backup (above).
3. Change the image tag and restart:

   ```sh
   sudoedit /etc/containers/systemd/haychat-server.container   # Image=...:v0.2.0
   sudo systemctl daemon-reload
   sudo systemctl restart haychat-server.service
   ```

   With plain podman: `podman pull` the new tag, `podman rm -f haychat-server`, and run it
   again with the same volumes.
4. Watch the log for `=== Server Running ===`. Keep the `haychat-storage` volume: it holds the
   identity key that every client has pinned.

## Running the Server Binary Without Containers

Each release also attaches `haychat-server-VERSION-linux-x86_64.tar.gz`: the server binary,
`env.example`, this guide as `DEPLOY.md`, and the SQL helpers. It is built on Fedora 44 and
needs glibc 2.34 or newer, `libpq.so.5`, and `libenet.so.7` (Fedora `libpq enet`, Debian and
Ubuntu `libpq5 libenet7`), plus a PostgreSQL it can reach through `HAYCHAT_DATABASE_*`. Run it
from a directory it can write to (relative paths resolve against the working directory) and
stop it with SIGINT. Outside a container io_uring is available unless the host disables it.

## Release Builds

`.forgejo/workflows/release.yml` runs on a pushed tag `v*` and on demand (Actions, "Release",
Run workflow). To cut a release:

```sh
git tag -a v0.1.0 -m "HayChat v0.1.0"
git push origin v0.1.0
```

| Job | What it does |
| --- | --- |
| `archives` | In a Fedora 44 job container with the same package script and Odin pins as CI, runs `deploy/release-artifacts.sh VERSION dist --windows` and keeps `dist/` as a workflow artifact |
| `image` | On a tag (or a manual run with `push_image`): builds `deploy/Containerfile` with buildah and pushes `git.spyingwind.com/jim/haychat/server:TAG` and `:latest` (`:edge` for manual runs) |
| `release` | On a tag: creates a pre-release named after the tag (or reuses it on a re-run) and uploads the archives and `SHA256SUMS` through the Forgejo API |

Release assets:

| Asset | Contents |
| --- | --- |
| `haychat-server-TAG-linux-x86_64.tar.gz` | Server binary, SQL helpers, `DEPLOY.md`, `env.example`, licence |
| `haychat-client-TAG-linux-x86_64.tar.gz` | `haychat-client`, `README.txt`, licences |
| `haychat-client-TAG-windows-x86_64.zip` | `haychat-client.exe`, `SDL3.dll`, `SDL3_ttf.dll`, `README.txt`, licences |
| `SHA256SUMS` | Checksums of the three archives |

**Token.** The jobs authenticate with the repository secret `RELEASE_TOKEN` when it exists,
otherwise with the automatic job token. Create `RELEASE_TOKEN` (Settings, Actions, Secrets)
from a personal access token of the repository owner with the scopes `write:package` and
`write:repository`: depending on the Forgejo version, the automatic token may not be allowed
to push to the container registry.

**Building images on the runner.** The `image` job runs buildah inside the job container,
with chroot isolation and the vfs storage driver, so it needs no privileges beyond what the
runner already grants for CI (`label=disable` from the runner's `config.yml`). The job's
exact `buildah build` command built the full image inside a rootless podman `fedora:44`
container started with those options (default capabilities, the io_uring seccomp profile,
`label=disable`); it has not run on the runner itself yet, and pushing is untested. If the
runner cannot build images, the `image` job fails, the release is still published with the
archives (including the server binary), and its notes say the image was not pushed; build the
image on the server host with `podman build -f deploy/Containerfile .` instead.

**The Linux client** is linked against the system SDL3, SDL3_ttf, and ENet rather than
bundling them: the Fedora 44 builds of SDL3_ttf pull in FreeType, HarfBuzz, PlutoSVG, and
GLib, and copying that chain onto other distributions is fragile. Its `README.txt` tells
testers which packages to install (Fedora `SDL3 SDL3_ttf enet`, Ubuntu 25.04+ and Debian 13+
`libsdl3-0 libsdl3-ttf0 libenet7`). The binary needs glibc 2.34 or newer.

**The Windows client is cross-compiled on Linux.** The pinned Odin refuses a Windows target
without `-windows-sdk-root:PATH` and links it with `lld-link`, which needs the MSVC CRT and
Windows SDK import libraries. `deploy/release-artifacts.sh` downloads them with
[xwin](https://github.com/Jake-Shadle/xwin) (pinned version and checksum, about 1 GB of
downloads, splatted into `winsysroot` layout and cached by the workflow) and builds with
`odin build client -target:windows_amd64 -linker:lld -windows-sdk-root:...`. The workflow sets
`HAYCHAT_ACCEPT_MSVC_LICENSE=1`, which accepts Microsoft's licence terms for those libraries on
the maintainer's behalf; remove `--windows` from the `archives` job if you do not want that.
The script also fetches `SDL3.dll` and `SDL3.lib` with `git lfs`: the pinned Odin checkout
stores them as Git LFS pointers, so a plain clone has 130-byte placeholders. The zip ships
`SDL3.dll` and `SDL3_ttf.dll` with their licences (zlib; SDL3_ttf.dll also contains FreeType,
HarfBuzz, PlutoSVG, and PlutoVG, whose licences are included). The cross-built client was run
under Wine in headless mode against the release image and connected and chatted; it has not
been run on a real Windows machine yet.

To reproduce a release build locally (the archives land in `dist/`, which `.gitignore`
excludes):

```sh
./dev.sh shell
dnf install -y git-lfs
HAYCHAT_ACCEPT_MSVC_LICENSE=1 HAYCHAT_XWIN_CACHE=/src/.cache/xwin \
	deploy/release-artifacts.sh v0.0.0-local dist --windows
```

Leave out `--windows` (and the variables) for the server and Linux client only.

### Building the Windows Client on Windows

Without the cross-build, build on a Windows machine with the same Odin commit as
`dev/bootstrap-odin.sh` (`ODIN_COMMIT`):

1. Install the Visual Studio Build Tools with the "Desktop development with C++" workload, and
   Git for Windows (it includes Git LFS).
2. In an "x64 Native Tools Command Prompt":

   ```bat
   git clone https://github.com/odin-lang/Odin.git C:\Odin
   cd C:\Odin
   git checkout <ODIN_COMMIT from dev\bootstrap-odin.sh>
   git lfs pull --include "vendor/sdl3/*"
   build.bat release
   ```

3. From the HayChat checkout:

   ```bat
   C:\Odin\odin.exe build client -o:speed -out:haychat-client.exe
   copy C:\Odin\vendor\sdl3\SDL3.dll .
   copy C:\Odin\vendor\sdl3\ttf\SDL3_ttf.dll .
   ```

   Ship `haychat-client.exe` with both DLLs, `C:\Odin\vendor\sdl3\LICENSE.txt`, and the
   `LICENSE*.txt` files from `C:\Odin\vendor\sdl3\ttf\`.

# Deploying HayChat

<!-- This file also ships as DEPLOY.md in the server release archive, so links are absolute. -->

This guide is for the person who runs a HayChat server for testers. It covers the production
server image, running it with PostgreSQL under podman, first-time setup, backups, upgrades,
and the release builds that produce the image and the client downloads. Testers need only
[docs/tester-guide.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/tester-guide.md).

> [!NOTE]
> HayChat is unreleased. A new server version migrates the database in place on startup and
> never drops data, but it cannot be downgraded without the backup taken before the upgrade.
> Take a backup before every upgrade (see [Upgrades](#upgrades)).

## What Is Here

| File                             | Purpose                                                                                                                                |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `deploy/Containerfile`           | Multi-stage build of the server image: Fedora 44 with the pinned Odin toolchain builds the server; a `fedora-minimal:44` stage runs it |
| `deploy/quadlet/`                | systemd units (podman quadlet): `haychat.pod`, `haychat-db.container`, `haychat-server.container`                                      |
| `deploy/sql/make-admin.sql`      | Gives one existing account the admin role                                                                                              |
| `deploy/sql/create-invite.sql`   | Prints a new invite code, for a server that is not Open and has no admin yet                                                           |
| `deploy/sql/set-registration-mode.sql` | Sets the registration mode (`open`, `invite`, `approval`) without a client                                                       |
| `deploy/sql/set-restricted.sql` | Restricts one account or lifts its restriction without a client; a running server applies it at once                             |
| `deploy/sql/attachment-usage.sql` | Shows attachment storage use: totals, the accounts that store the most, and one account's files                                 |
| `deploy/sql/remove-attachment.sql` | Removes one attachment by its blob ID; the server deletes the file within the hour                                             |
| `deploy/sql/truncate-room-log.sql` | Truncates an encrypted room's damaged member log to the version the server reported; restart the server after             |
| `deploy/release-artifacts.sh`    | Builds the server binary and client archives for a release                                                                             |
| `deploy/client-README-*.txt`     | The `README.txt` shipped in each client archive                                                                                        |
| `THIRD_PARTY_NOTICES.md`         | Third-party components, licences and credits of each artifact; shipped as `THIRD_PARTY_NOTICES.txt`                                    |
| `.forgejo/workflows/release.yml` | Release builds on Forgejo (see [Release Builds](#release-builds))                                                                      |
| `.containerignore`               | Limits the image's build context to the files it needs                                                                                 |

## The Server Image

Releases push the image to the repository's container registry:

```sh
podman pull git.spyingwind.com/quonic/haychat/server:v0.1.0   # or :latest
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

| Property          | Value                                                                                                                                                                                                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Base              | `registry.fedoraproject.org/fedora-minimal:44`, about 150 MB in total                                                                                                                                                                                                          |
| Runtime packages  | `libpq` and `enet` (the binary links `libpq.so.5`, `libenet.so.7`, and glibc)                                                                                                                                                                                                  |
| Entrypoint        | `/usr/local/bin/haychat-server`                                                                                                                                                                                                                                                |
| User              | `haychat`, UID/GID `10001`, not root                                                                                                                                                                                                                                           |
| Working directory | `/var/lib/haychat`                                                                                                                                                                                                                                                             |
| Volumes           | `/var/lib/haychat/logs` (`HAYCHAT_LOG_DIR`), `/var/lib/haychat/storage` (`HAYCHAT_FILE_STORAGE_PATH`: server identity key) and `/var/lib/haychat/attachments` (`HAYCHAT_ATTACHMENT_DIR`: attachment files, protocol 26)                                                       |
| Port              | `12345/udp` (clients)                                                                                                                                                                                                                                                          |
| Stop signal       | `SIGINT`, the server's graceful shutdown; it stops its worker threads and exits 0                                                                                                                                                                                              |
| Also included     | `/usr/share/haychat/sql/` (`make-admin.sql`, `create-invite.sql`, `set-registration-mode.sql`, `set-restricted.sql`, `attachment-usage.sql`, `remove-attachment.sql`, `truncate-room-log.sql`, `auth_bootstrap.sql`); `/usr/share/licenses/haychat-server/` (`LICENSE`, `THIRD_PARTY_NOTICES.txt`, and `licenses/` with the Odin, compiler-rt and pg licences); the Fedora packages' licences in `/usr/share/licenses/<package>` |

The image sets `HAYCHAT_LISTEN_ADDR=0.0.0.0`, `HAYCHAT_LISTEN_PORT=12345`, and the four
path variables (`HAYCHAT_LOG_DIR`, `HAYCHAT_FILE_STORAGE_PATH`,
`HAYCHAT_SERVER_IDENTITY_FILE`, `HAYCHAT_ATTACHMENT_DIR`) to match the volumes.

The server writes its log to stdout (read it with `journalctl` or `podman logs`).
`HAYCHAT_LOG_DIR` is created at startup and reserved for log files. The server needs no
special container settings: it runs under podman's default seccomp profile and, on SELinux
hosts, the default `container_t` label.

## Running With Quadlet (Recommended)

The units in `deploy/quadlet/` run PostgreSQL 17 and the server as systemd services in one
pod. The two containers share the pod's network and reach each other on `127.0.0.1`; the pod
publishes only UDP `12345`, so PostgreSQL is not reachable from outside.

Quadlet rather than a `podman kube play` YAML: systemd restarts the services on failure and
starts them at boot, logs go to the journal, and the settings the server needs (`Secret=`,
`RunInit=`) are plain quadlet keys instead of Kubernetes annotations. The `.pod` unit needs **podman 5.0 or newer** (Fedora 40+,
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

2. Create the config directory and the server's environment file (it must exist, even if
   empty):

   ```sh
   sudo mkdir -p /etc/haychat-server
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
   ```

   After that the server logs a `[Status]` line every five minutes (see
   [Server Status](#server-status)).

5. Open the firewall (see [Network](#network)) and continue with
   [First-Time Setup](#first-time-setup).

## Running With Plain Podman

The same setup by hand, useful for a first try or on podman 4:

```sh
openssl rand -base64 32 | tr -d '\n' | podman secret create haychat-db-password -

podman pod create --name haychat -p 12345:12345/udp

podman run -d --pod haychat --name haychat-db \
	-e POSTGRES_USER=haychat -e POSTGRES_DB=haychat \
	--secret haychat-db-password,type=env,target=POSTGRES_PASSWORD \
	-v haychat-pgdata:/var/lib/postgresql/data \
	docker.io/library/postgres:17

podman run -d --pod haychat --name haychat-server --init \
	-e HAYCHAT_DATABASE_URL=127.0.0.1 \
	--secret haychat-db-password,type=env,target=HAYCHAT_DATABASE_PASS \
	--env-file "$HOME/.config/haychat-server/server.env" \
	-v haychat-logs:/var/lib/haychat/logs \
	-v haychat-storage:/var/lib/haychat/storage \
	-v haychat-attachments:/var/lib/haychat/attachments \
	git.spyingwind.com/quonic/haychat/server:v0.1.0

podman logs -f haychat-server       # "=== Server Running ===" means it is ready
```

Start PostgreSQL first: the server exits when it cannot reach the database at startup. Every
failed start prints a line starting with `[Startup]` and exits with status 1, so
`--restart on-failure` brings it back; a clean shutdown exits 0. The quadlet units start the
server only after PostgreSQL reports healthy and restart it on any exit. `podman stop haychat-server` sends SIGINT
and waits for the graceful shutdown. Leave out `--env-file` when you have no overrides.

## Environment Variables

Every server setting is a `HAYCHAT_*` environment variable; [docs/server-configuration.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/server-configuration.md)
lists them all with defaults, and [`.env.example`](https://git.spyingwind.com/quonic/haychat/src/branch/main/.env.example) documents the optional ones. In this
deployment:

| Set by                                  | Variables                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The image                               | `HAYCHAT_LISTEN_ADDR`, `HAYCHAT_LISTEN_PORT`, `HAYCHAT_LOG_DIR`, `HAYCHAT_FILE_STORAGE_PATH`, `HAYCHAT_SERVER_IDENTITY_FILE`, `HAYCHAT_ATTACHMENT_DIR`                                                                                                                                                                                                                                                                      |
| The quadlet unit (or your `podman run`) | `HAYCHAT_DATABASE_URL=127.0.0.1`, `HAYCHAT_DATABASE_PORT`, `HAYCHAT_DATABASE_USER`, `HAYCHAT_DATABASE_NAME`, and `HAYCHAT_DATABASE_PASS` from the `haychat-db-password` secret                                                                                                                                                                                                                                               |
| You, in `server.env` (all optional)     | `HAYCHAT_LOG_LEVEL`, `HAYCHAT_MAX_RESTARTS`, `HAYCHAT_RESTART_BACKOFF_MIN`, `HAYCHAT_RESTART_BACKOFF_MAX`, `HAYCHAT_MAX_NETWORK_THREADS`, `HAYCHAT_ADMIN_PUBLIC_KEY`, `HAYCHAT_SERVER_PRIVATE_KEY`, `HAYCHAT_SERVER_PUBLIC_KEY`, `HAYCHAT_VOICE_ENABLED`, `HAYCHAT_VOICE_MAX_PARTICIPANTS`, `HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND`, `HAYCHAT_VOICE_MAX_FRAME_BYTES`, the `HAYCHAT_ATTACHMENT*` limits (see [Attachment Storage](#attachment-storage-and-removing-files))                            |

`server.env` holds a secret when you set a fixed server key, so keep it
at mode `0600`. To keep the server listening on another port inside the pod, set
`HAYCHAT_LISTEN_PORT` and change the pod's `PublishPort=` to match; changing only the left
side of `PublishPort=` is simpler.

Voice is on by default in every room. `HAYCHAT_VOICE_ENABLED=false` turns it off;
`HAYCHAT_VOICE_MAX_PARTICIPANTS` (default 25) caps each room, and
`HAYCHAT_VOICE_MAX_PACKETS_PER_SECOND` (60) and `HAYCHAT_VOICE_MAX_FRAME_BYTES` (512) bound
what one connection may send. [docs/server-configuration.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/server-configuration.md#voice)
describes each one.

## Network

Clients connect over **UDP port 12345** (or the host port you published). Open it on the
host firewall and on any cloud security group or router in front of the host:

```sh
sudo firewall-cmd --permanent --add-port=12345/udp && sudo firewall-cmd --reload   # firewalld
sudo ufw allow 12345/udp                                                           # ufw
```

Voice uses the same port (it is another ENet channel on the same connection), so there is no
second port to open. Nothing else needs to be reachable. Give testers the host name (or public IP address) and the
port. The transport is encrypted (X25519 key exchange, XChaCha20-Poly1305) and every client
pins the server's identity key on its first connection, so no TLS certificate is involved.

## First-Time Setup

A fresh server is ready to chat: on its first start (whenever the `rooms` table is empty) it
creates `#general` as room 1, a Public room that every account joins. The log shows
`Created default room #general`. Testers only need the host and port.

Optionally, give your own account the admin role, which lets it create, rename, and delete
rooms from the client (**+ New room** next to the room list, **Edit room** in a room's
header), and grant the role to others, rename, kick, ban and unban accounts, and choose a
room's type (see [docs/rooms-and-accounts.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/rooms-and-accounts.md#admin-actions)):

1. Connect once with the client, using the display name that should own the server (for
   example `quonic`). The server creates the account and binds the name to your client's key.
2. Run `deploy/sql/make-admin.sql` against the database:

   ```sh
   podman exec -i haychat-db psql -U haychat -d haychat -v owner=quonic <deploy/sql/make-admin.sql
   ```

   Without a checkout, use the copy in the image:

   ```sh
   podman exec haychat-server cat /usr/share/haychat/sql/make-admin.sql \
   	| podman exec -i haychat-db psql -U haychat -d haychat -v owner=quonic
   ```

   It prints `quonic is an admin`. It fails without changing anything when no account has that
   name, and it is safe to run again. The equivalent statements, for typing into
   `podman exec -it haychat-db psql -U haychat -d haychat`:

   ```sql
   INSERT INTO server_roles (name) VALUES ('admin') ON CONFLICT DO NOTHING;
   INSERT INTO user_server_roles (user_id, role_id)
   	SELECT u.id, r.id FROM users u, server_roles r WHERE u.nickname = 'quonic' AND r.name = 'admin'
   	ON CONFLICT DO NOTHING;
   ```

3. Reconnect: a role set in the database reaches the client when it signs in, so close and
   reopen it (or wait for its next reconnect). The room controls then appear. Admins you
   appoint from the client afterwards get the role at once, without reconnecting.

A banned account cannot sign in. While sign-up is open, a banned person can connect again with
a new identity key as a new account; close sign-up to stop that (below).

### Registration Mode and Invite Codes

A new or upgraded server is **Open**: anyone who connects gets an account. An admin changes the
mode from the client (Server settings, Admin), or you set it with SQL:

```sh
podman exec -i haychat-db psql -U haychat -d haychat -v mode=invite <deploy/sql/set-registration-mode.sql
```

`mode` is `open`, `invite` (a valid invite code is needed) or `approval` (a valid code makes a
sign-up request with a written reason, which an account with Approve registrations accepts or
declines). New sign-ins follow it at once.

To close sign-up before anyone has an account, either set `HAYCHAT_ADMIN_PUBLIC_KEY` to your
client's key (that key may always sign up, in every mode, and you then run `make-admin.sql`
for it as above), or print an invite code and sign up with it:

```sh
podman exec -i haychat-db psql -U haychat -d haychat -v uses=1 -v days=7 \
	-v note='first admin' <deploy/sql/create-invite.sql
```

It prints the code once (only its sha256 is stored). `uses` (default 1, 0 for no limit),
`days` (default 7, 0 for never) and `note` are optional, and `-v skip_approval=true` lets the
code sign up without approval in `approval` mode. Then run `make-admin.sql` for the name you
signed up with. Admins and accounts with Create invites make further codes from the client
(Server settings → Admin → **Invites**), each with a `haychat://` invite link that carries the
server's key; accounts with Approve sign-ups decide requests under **Sign-up requests**. See
[the user guide](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/user-guide.md#signing-up)
and [the server's rules](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/rooms-and-accounts.md#registration).

`server/sql/auth_bootstrap.sql` (also in the image) is the **test fixture** the dev
environment uses. It creates the accounts `admin` (ID 1) and `haypeer` (ID 2) and resets `#general`,
and it **deletes any account that holds ID 1 or 2 under another name**, with its messages.
Load it only into an empty database, and only if you want those accounts.

### Restricted Accounts

A restricted account sees and is seen by only the accounts it shares a room with, and admins
([the rules](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/rooms-and-accounts.md#restricted-accounts)).
Room codes make them; an admin restricts or lifts from the client, or you do it with SQL:

```sh
podman exec -i haychat-db psql -U haychat -d haychat -v account=erin -v restricted=true \
	<deploy/sql/set-restricted.sql
```

`restricted` is `true` or `false`; lifting also adds the account to every Public room. No
restart is needed: the server listens for changes to `users.restricted` (migration 18,
`LISTEN haychat_restricted` on a connection of its own), so the account's sessions and
everyone's user lists follow at once, as after an admin's change from a client. A plain
`UPDATE users SET restricted = ...` reaches a running server the same way, but joins no Public
rooms while the server is stopped; the helper does. If the server's listener connection drops,
it reconnects and reads the restricted accounts again, so nothing is missed.

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

## Server Status

The server has no admin port. Every five minutes, and once when it shuts down, it logs one
`[Status]` line of `key=value` pairs: uptime, connected peers, whether the network and
database services are running or waiting to restart, and the voice counters (rooms,
participants, frames in and out, drops by reason; see [docs/server-configuration.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/server-configuration.md#status-log)).
Read it with:

```sh
sudo journalctl -u haychat-server.service | grep -F '[Status]' | tail -n 1
podman logs haychat-server 2>&1 | grep -F '[Status]' | tail -n 1     # plain podman
```

The quadlet unit has no `HealthCmd`; systemd restarts the server whenever it exits.

## Backups

Back up three things together: the database, the server's storage volume (`haychat-storage`,
the identity key) and its attachments volume (`haychat-attachments`, `HAYCHAT_ATTACHMENT_DIR`,
the uploaded files). The files' names, owners, hashes and messages are rows in the database,
so neither half is complete without the other. Take the database dump first and the
attachments volume right after it:

```sh
podman exec haychat-db pg_dump -U haychat -d haychat -Fc >"haychat-$(date +%F).dump"
podman volume export haychat-storage >"haychat-storage-$(date +%F).tar"
podman volume export haychat-attachments >"haychat-attachments-$(date +%F).tar"
```

In that order the worst case is a file finished between the two commands: it has no row in the
dump, so after a restore the startup scan deletes it, and its message is not in the dump either.
For an exact pair, stop the server (`systemctl stop haychat-server.service` or `podman stop
haychat-server`) for the two commands and start it again after. Finished files are renamed into
`blobs/` only once they are complete, so the archive never holds half a finished file; uploads
in progress (`incoming/*.part`) are dropped on restore.

The storage archive holds the server's private key: store it as privately as the database
dump. The attachments archive holds every file of unencrypted rooms and conversations in the
clear (files of encrypted ones are ciphertext).

### Restoring

The order matters: **the database first, then the blob directory**, and the server must not run
with the restored files before their rows are back. At every start the server deletes each file
in the blob directory that is older than an hour and has no row (the startup scan). Two guards
stop it from deleting a backup's files when the order went wrong; each keeps every such file,
deletes nothing and logs a warning with the counts:

- **An empty table:** the `attachments` table has no row at all but the blob directory holds
  files (a fresh database beside the restored attachments volume). The log says
  `[Attachments] Warning: the attachments table is empty but the blob directory holds N files
  older than an hour; kept them all. ...`.
- **Too many orphans:** more than 10% of the files the scan found have no row, and more than 10
  of them (an older dump beside a newer volume). The log says `[Attachments] Warning: N of the M
  files older than an hour in the blob directory have no row (more than 10%); kept them all.
  ...`. Up to 10 orphans are always deleted, so a stray file in a small directory still goes.

After either warning, stop the server and restore the pair as below. When the files really
should go (the dump is right and the files are leftovers), start the server **once** with
`HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE=1` (in `/etc/haychat-server/server.env`, or `-e` on `podman
run`): that start deletes them past both guards and logs `[Attachments]
HAYCHAT_ATTACHMENT_ALLOW_ORPHAN_PURGE is set: deleting N orphan files of M past the guards`.
Remove the variable right after, because the server reads it at every start and the guards stay
off while it is set. The hourly sweeper is not guarded: it deletes files only with their rows.

1. Import the storage volume before the first start: `podman volume create haychat-storage &&
   podman volume import haychat-storage FILE.tar`. Leave the attachments volume empty for now.
2. Start the pod (`systemctl start haychat-pod.service`, or the `podman run` commands). The
   server creates an empty schema and an empty blob directory, which is harmless.
3. Stop the server, empty the database and load the dump:

   ```sh
   sudo systemctl stop haychat-server.service        # or: podman stop haychat-server
   podman exec haychat-db psql -U haychat -d haychat -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public'
   podman exec -i haychat-db pg_restore -U haychat -d haychat <FILE.dump
   ```

4. With the server still stopped, import the attachments volume: `podman volume import
   haychat-attachments FILE.tar`.
5. Start the server again (`systemctl start haychat-server.service` or `podman start
   haychat-server`).

Emptying the schema first matters: the server's own `schema_migrations` table must come from
the dump, not from the server that ran before it. A dump from an older server version is
migrated on that start, exactly like an upgrade (see below).

What a mismatched pair does:

- **A row without its file** (the blob directory is older than the dump, or was lost): the
  message still lists the file, but a download fails with "Attachment not found" (clients show
  "Attachment unavailable"). The server is not a backup, so it then marks that file removed, as
  an admin removal would: the card reads "Attachment removed by an admin", and Server settings →
  **Removed files** lists it with the reason "File missing from storage" and no admin. It marks
  nothing while `blobs/` is missing, unreadable or empty, or the file's shard directory
  `blobs/<2 hex>` is missing (a volume that did not mount), and at most 10 files an hour; it
  logs `[Attachments] WARNING: ...` in both cases. A file it did not mark stays listed and is
  tried again on its next download. Restore the blob directory before readers try its files.
- **A file without a row** (the blob directory is newer than the dump): the startup scan deletes
  it once the file is an hour old and logs `[Attachments] Deleted N orphan attachment files`,
  unless a guard above keeps it (an empty table, or more than 10% and more than 10 such files).

The server refuses an attachment directory that is the storage directory or holds the identity
file, so the two volumes cannot be mixed up.

### Attachment Storage and Removing Files

Uploaded files live in the `haychat-attachments` volume (`/var/lib/haychat/attachments`):
`incoming/<blob>.part` while an upload runs and `blobs/<2 hex>/<blob>` once it is finished, mode
0600 in 0700 directories, named only by the server's random blob IDs. The server keeps a free-disk
reserve on that volume (`HAYCHAT_ATTACHMENT_MIN_FREE_BYTES`, 1 GiB) and refuses uploads that
would go below it with "Server storage is full"; giving the volume its own file system keeps a
full disk away from the database and the logs. The limits (25 MiB per file, 1 GiB per account,
512 MiB uploaded per account per hour, no global cap) and every other `HAYCHAT_ATTACHMENT*`
variable are in [docs/server-configuration.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/server-configuration.md#attachments).

The server cleans the volume by itself. Hourly and at every start it deletes the rows and then
the files of uploads that stalled (no data for an hour) or were never sent with a message
(`HAYCHAT_ATTACHMENT_PENDING_HOURS`, 24), of cancelled uploads, and of files whose message is
gone (a deleted room's files, for example), each at least an hour after the upload began. At
every start it also deletes files that have no row, unless the guards in
[Restoring](#restoring) keep them. The `[Status]` line counts both (`attachment_blobs_swept`,
`attachment_orphans`) and the orphans the guards kept (`attachment_orphans_kept`).

Admins see storage use and remove files from the client (Server settings → **Storage**, after
the Admin section, and **Remove attachment…** in a file card's right-click menu; protocol 28),
and since protocol 29 every past removal with its reason (Server settings → **Removed files**).
Without a client, use the SQL helpers:

```sh
podman exec -i haychat-db psql -U haychat -d haychat <deploy/sql/attachment-usage.sql
podman exec -i haychat-db psql -U haychat -d haychat -v owner=alice <deploy/sql/attachment-usage.sql
podman exec -i haychat-db psql -U haychat -d haychat \
	-v blob=0123456789abcdef0123456789abcdef <deploy/sql/remove-attachment.sql
podman exec -i haychat-db psql -U haychat -d haychat \
	-v blob=0123456789abcdef0123456789abcdef -v reason='Reported as spam' \
	<deploy/sql/remove-attachment.sql
```

The image carries them in `/usr/share/haychat/sql/` too. `attachment-usage.sql` prints the
stored bytes (removed files count toward nothing), the top accounts (`-v limit=N`, default 100)
and, with `-v owner=NAME`, that account's files with their blob IDs. `remove-attachment.sql`
makes the file a removed tombstone, as an admin's removal does: its message stays and lists it
as removed, nobody can download it, and it frees its owner's quota. It refuses an unknown,
uploading or already removed blob. SQL cannot reach the running server, so the file itself is
deleted by the server's hourly pass (and at its next start), and connected clients see the
removal on their next history fetch, as with other changes made in the database. An admin who
removes a file from the client deletes it at once and tells everyone who may read its message.

Both ways add a row to the removal log, the `attachment_removals` table (migration 16): the
blob, its owner, the admin (empty for `remove-attachment.sql`), the time, the reason, the room
or direct conversation, the message and a plaintext file's name (an encrypted file's name never
reaches the server). `remove-attachment.sql` takes the reason as `-v reason=...`: optional, at
most 500 bytes with no control characters. Admins list the log in the client, where a removal
made in SQL reads "removed by an operator". Rows are kept indefinitely, since removals are rare,
and are not tied to the `attachments` row, so a row stays after the server deletes a removed
file's row. An admin's reason also still goes to the server's log
(`[Admin] Attachment ... removed by user ...: REASON`).

### Damaged Encrypted Room Member Logs

An encrypted room's member list is a signed log (`room_log_entries`). When the stored log no
longer replays (a restore that mixed rows from two backups, or a change made in SQL), the
server refuses every change to that room's members and a ban reports the room as one it could
not change. The server's log then says which version to keep:

```text
[RoomLog] Room 12's member log is damaged: version 5 does not replay (BadSignature); it replays
to version 4 of 6 stored entries, and the room's head is version 6. Truncate it to version 4
(...)
```

The way to repair it is from an admin's client: Server settings → **Member logs** → **Check
member logs** lists every damaged room with the same facts, and **Truncate log to version N…**
deletes everything after version N on the running server and tells the room's members
([protocol 35](https://git.spyingwind.com/quonic/haychat/src/branch/main/docs/protocol.md#repairing-a-damaged-member-log-protocol-35)).
Without an admin, use the SQL helper with the version from the log line:

```sh
podman exec -i haychat-db psql -U haychat -d haychat \
	-v room_id=12 -v to_version=4 <deploy/sql/truncate-room-log.sql
sudo systemctl restart haychat-server.service        # or: podman restart haychat-server
```

SQL cannot check the entries' signatures, so give it exactly the version the server reported:
a lower one undoes real member changes, and a higher one leaves the log damaged. It refuses a
room that does not exist or is not encrypted, a version below 1 (a room whose first entry does
not replay can only be deleted), a version whose earlier entries are missing, and a log that
already ends there. In one transaction it deletes the entries after that version, the room's
key envelopes, sealed messages and sealed edits of the later versions (their files are deleted
by the server's hourly sweeper), sets the room's members, log managers and access to what they
were at that version, and sets its head. **Restart the server afterwards**: SQL cannot reach
it, so until then connected clients keep what they had and the room's voice keeps the old
version. Members whose app had verified a later version see "This room's member list was
changed on the server" for the room; the others carry on after restarting their app.

## Upgrades

The server migrates its database at startup. It records every applied migration in the
`schema_migrations` table, applies the missing ones in order inside one transaction, and logs
one line per migration, for example `[Database] Applied database migration 2 (read markers)`.
A database from v0.1.0-rc1, which has no `schema_migrations` yet, is adopted as version 1
(`[Database] Adopted the existing database schema as migration 1 (baseline)`) with every
account, room, and message kept. A start that changes nothing logs nothing extra. Two servers
started against one database take turns: the migration holds a PostgreSQL advisory lock.

The server never drops tables on its own. It refuses to start, prints a `[Startup]` line, and
exits with status 1, leaving the database exactly as it was, when:

- the database records a newer schema version than the server knows ("database schema version
  N is newer than this server supports (M)"), which means a downgrade;
- the HayChat tables have no recorded version and do not match the v0.1.0-rc1 schema;
- a migration fails, or the migrated schema fails the server's checks.

1. Read the release notes: they say whether the schema or the protocol version changed. A
   protocol change means every tester must update the client too; older clients show "This
   client and the server speak different protocol versions".
2. Take a backup (above). Migrations only add to the schema, but the backup is the only way
   back to the older server version.
3. Change the image tag and restart:

   ```sh
   sudoedit /etc/containers/systemd/haychat-server.container   # Image=...:v0.2.0
   sudo systemctl daemon-reload
   sudo systemctl restart haychat-server.service
   ```

   With plain podman: `podman pull` the new tag, `podman rm -f haychat-server`, and run it
   again with the same volumes.

4. Watch the log for the migration lines and `=== Server Running ===`. Keep the
   `haychat-storage` volume: it holds the identity key that every client has pinned.

### Upgrading From a Server With the Web Admin

Servers before this change ran an HTTP web admin on `127.0.0.1:8080`, which needed io_uring
and therefore a custom seccomp profile and SELinux turned off. It is gone; the `[Status]` log
line replaces `/status`. When you upgrade from such a server:

- Install the new `haychat-server.container`, or remove `SeccompProfile=`,
  `SecurityLabelDisable=`, and the `HealthCmd=`/`HealthInterval=`/`HealthStartPeriod=` lines
  from your copy, then `systemctl daemon-reload`. With plain podman, drop
  `--security-opt label=disable` and `--security-opt seccomp=...`.
- Delete `seccomp-io-uring.json` from the config directory.
- `HAYCHAT_WEB_ADMIN_PORT` and `HAYCHAT_WEB_ADMIN_TOKEN` are ignored; remove them from
  `server.env`. The old `storage/web_admin_token` file is no longer read and can be deleted.

### Downgrading

An older server refuses a database that a newer one migrated. To go back, stop the server,
restore the backup taken before the upgrade as in [Backups](#backups) (empty the schema, then
`pg_restore`), set the older image tag, and start it. Messages sent since the upgrade are lost
with that restore, so downgrade only to recover from a broken release.

### Resetting a Throwaway Database

A test server whose data does not matter can start over instead. This deletes every account,
room, and message; the server recreates the schema and `#general` on its next start. Stop the
server first, then either empty the schema:

```sh
podman exec haychat-db psql -U haychat -d haychat -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public'
```

or remove the database volume (`podman rm -f haychat-db && podman volume rm haychat-pgdata`,
then start the pod again). Keep `haychat-storage` so clients still recognise the server's
identity key; repeat [First-Time Setup](#first-time-setup) for the admin role. In the dev
environment, `./dev.sh reset` does this.

## Running the Server Binary Without Containers

Each release also attaches `haychat-server-VERSION-linux-x86_64.tar.gz`: the server binary,
`env.example`, this guide as `DEPLOY.md`, the SQL helpers, `LICENSE`,
`THIRD_PARTY_NOTICES.txt`, and `licenses/`. It is built on Fedora 44 and needs glibc 2.34 or
newer, `libpq.so.5`, and `libenet.so.7` (Fedora `libpq enet`, Debian and
Ubuntu `libpq5 libenet7`), plus a PostgreSQL it can reach through `HAYCHAT_DATABASE_*`. Run it
from a directory it can write to (relative paths resolve against the working directory) and
stop it with SIGINT.

## Release Builds

`.forgejo/workflows/release.yml` runs on a pushed tag `v*` and on demand (Actions, "Release",
Run workflow). To cut a release:

```sh
git tag -a v0.1.0 -m "HayChat v0.1.0"
git push origin v0.1.0
```

| Job        | What it does                                                                                                                                                                               |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `archives` | In a Fedora 44 job container with the same package script and Odin pins as CI, runs `deploy/release-artifacts.sh VERSION dist --windows` and keeps `dist/` as a workflow artifact          |
| `image`    | On a tag (or a manual run with `push_image`): builds `deploy/Containerfile` with buildah and pushes `git.spyingwind.com/quonic/haychat/server:TAG` and `:latest` (`:edge` for manual runs) |
| `release`  | On a tag: creates a pre-release named after the tag (or reuses it on a re-run) and uploads the archives and `SHA256SUMS` through the Forgejo API                                           |

Release assets:

| Asset                                    | Contents                                                                                                                                                                                                                |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `haychat-server-TAG-linux-x86_64.tar.gz` | Server binary, SQL helpers, `DEPLOY.md`, `env.example`, `LICENSE`, `THIRD_PARTY_NOTICES.txt`, `licenses/` (Odin, compiler-rt, pg)                                                                                       |
| `haychat-client-TAG-linux-x86_64.tar.gz` | `haychat-client`, `libhaychat-webrtc-apm.so` (#171), `README.txt`, `LICENSE.txt`, `THIRD_PARTY_NOTICES.txt`, `licenses/` (Odin, compiler-rt, ENet, Inter, Twemoji, WebRTC)                                         |
| `haychat-client-TAG-windows-x86_64.zip`  | `haychat-client.exe`, `SDL3.dll`, `SDL3_ttf.dll`, `libopus-0.dll`, `rnnoise.dll`, `haychat-webrtc-apm.dll`, `README.txt`, `LICENSE.txt`, `THIRD_PARTY_NOTICES.txt`, `licenses/` (the Linux set plus SDL3, SDL3_ttf, FreeType, HarfBuzz, PlutoSVG, PlutoVG, Opus, RNNoise, WebRTC's third-party code, Abseil) |
| `SHA256SUMS`                             | Checksums of the three archives                                                                                                                                                                                         |

**Licences.** [THIRD_PARTY_NOTICES.md](https://git.spyingwind.com/quonic/haychat/src/branch/main/THIRD_PARTY_NOTICES.md)
says what each artifact contains and what each licence requires; the Windows `README.txt`
carries the FreeType credit, and both client READMEs the Twemoji attribution. The per-artifact
file lists are the `*_LICENCES` tables in `deploy/release-artifacts.sh`; the image build
stages the server list with `deploy/release-artifacts.sh --stage-licences server`. Every
build first runs `--check-licences`, which `./check.sh` also runs: it fails when a licence
file is missing, empty or a Git LFS pointer in the pinned toolchain, or when
`SDL3_ttf.dll` changes, because the FreeType credit year depends on the FreeType inside it
(2.13.2, 2023). After an Odin pin bump, re-check the notices as `THIRD_PARTY_NOTICES.md`
describes.

**Token.** The jobs authenticate with the repository secret `RELEASE_TOKEN` when it exists,
otherwise with the automatic job token. Create `RELEASE_TOKEN` (Settings, Actions, Secrets)
from a personal access token of the repository owner with the scopes `write:package` and
`write:repository`: depending on the Forgejo version, the automatic token may not be allowed
to push to the container registry.

**Building images on the runner.** The `image` job runs buildah inside the job container,
with chroot isolation and the vfs storage driver, so it needs no privileges beyond what the
runner already grants for CI (`label=disable` from the runner's `config.yml`). The
`v0.1.0-rc1` run proved both halves on the runner: the build takes about two and a half
minutes, and the push works with `RELEASE_TOKEN` but fails with the automatic job token
("authentication required" on the first blob upload). If the image job fails, the release is
still published with the archives (including the server binary) and its notes say the image
was not pushed. Fix the cause (usually the missing secret), re-run the failed job from the
run's page, and the release job re-runs after it: it reuses the release, replaces the
archives, and rewrites the notes. Without a working image job, build the image on the
server host with `podman build -f deploy/Containerfile .` instead.

**The Linux client** is linked against the system SDL3, SDL3_ttf, and ENet rather than
bundling them: the Fedora 44 builds of SDL3_ttf pull in FreeType, HarfBuzz, PlutoSVG, and
GLib, and copying that chain onto other distributions is fragile. It loads the system
libopus (`libopus.so.0`) at runtime for voice and starts without it. Its `README.txt` tells
testers which packages to install (Fedora `SDL3 SDL3_ttf enet opus`, Ubuntu 25.04+ and
Debian 13+ `libsdl3-0 libsdl3-ttf0 libenet7 libopus0`). The binary needs glibc 2.34 or newer.
Echo cancellation (#171) ships as HayChat's small wrapper `libhaychat-webrtc-apm.so` next to the
binary, built by `deploy/build-linux-webrtc-apm.sh` against the build host's
`webrtc-audio-processing-devel` (2.x); at runtime it needs the distribution's
`libwebrtc-audio-processing-2.so.1` (Fedora and Arch `webrtc-audio-processing`; Debian 13 and
Ubuntu have only 1.3), and without it the client runs without echo cancellation.

**The Windows client is cross-compiled on Linux.** The pinned Odin refuses a Windows target
without `-windows-sdk-root:PATH` and links it with `lld-link`, which needs the MSVC CRT and
Windows SDK import libraries. `deploy/release-artifacts.sh` downloads them with
[xwin](https://github.com/Jake-Shadle/xwin) (pinned version and checksum, about 1 GB of
downloads, splatted into `winsysroot` layout and cached by the workflow) and builds with
`odin build client -target:windows_amd64 -linker:lld -windows-sdk-root:...`. The workflow sets
`HAYCHAT_ACCEPT_MSVC_LICENSE=1`, which accepts Microsoft's licence terms for those libraries on
the maintainer's behalf; remove `--windows` from the `archives` job if you do not want that.
The script also fetches `SDL3.dll`, `SDL3.lib`, the SDL3_ttf files, and
`vendor/sdl3/mixer/libopus-0.dll` with `git lfs`: the pinned Odin checkout stores them as
Git LFS pointers, so a plain clone has 130-byte placeholders. The zip ships `SDL3.dll` and
`SDL3_ttf.dll` with their licences (zlib; SDL3.dll also contains HIDAPI, yuv2rgb, and fdlibm
code, and SDL3_ttf.dll FreeType, HarfBuzz, PlutoSVG, and PlutoVG, whose licences and notices
are included, and its `README.txt` carries the FreeType credit), and `libopus-0.dll` (the copy Odin ships for SDL3_mixer, which the client loads at
runtime for voice) with its BSD licence as `licenses/opus-LICENSE.txt`. It also builds
`rnnoise.dll` (`deploy/build-windows-rnnoise.sh`) and `haychat-webrtc-apm.dll`
(`deploy/build-windows-webrtc-apm.sh`: webrtc-audio-processing 2.1 and abseil 20240722.0 from
their pinned, checksummed source releases with Meson, clang-cl and lld-link against the same
sysroot, linked statically with HayChat's wrapper, static CRT, `/Brepro`; about 1 MB, importing
only `KERNEL32.dll` and `WINMM.dll`, and about 3.5 CPU-minutes to build). The cross-built
client was run under Wine in headless mode against the release image and connected and
chatted; it has not been run on a real Windows machine yet.

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
   copy C:\Odin\vendor\sdl3\mixer\libopus-0.dll .
   ```

   Ship `haychat-client.exe` with the three DLLs and everything the release zip carries
   besides them: `LICENSE`, `THIRD_PARTY_NOTICES.md`, `deploy/client-README-windows.txt` (it
   holds the FreeType credit), and the licence files that `WINDOWS_CLIENT_LICENCES` in
   `deploy/release-artifacts.sh` lists, from the repository and `C:\Odin`.

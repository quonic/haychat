# HayChat

![HayChat Logo](assets/icon.png)

HayChat is a self-hosted alternative to Discord: text rooms, direct messages and voice rooms on
a server you run yourself, with a lightweight native client for Windows and Linux.

> [!IMPORTANT]
> HayChat is in early development and not yet ready for production use. The project is
> open-source and welcomes contributions from the community.

## Features

- **Text rooms** with persistent, paged history, shared by every account on the server.
- **Direct messages** between any two accounts on a server, with online presence.
- **Voice rooms** with Opus audio, voice activity or push-to-talk (also while another window has
  focus), per-user volume and mute, and automatic re-join after a reconnect.
- **Unread counts** kept by the server, so they follow you to every device.
- **Several servers** in one client, each with its own display name and settings.
- **Administration from the client:** create, edit and delete rooms (text, voice, or both),
  grant the admin role, rename, kick, ban and unban accounts.
- **Encrypted transport:** Ed25519 identities, X25519 key exchange and XChaCha20-Poly1305, with
  the server's key pinned on first connect. No passwords: your identity key is your account.
  Messages are not end-to-end encrypted; the server can read them (see
  [docs/protocol.md](docs/protocol.md)).
- **Small footprint:** written in [Odin](https://odin-lang.org/), with its own immediate-mode UI
  on SDL3, a single-process server, and PostgreSQL for storage.

Windows and Linux are supported; macOS is planned.

### Why HayChat

- **Your server, your data:** open-source and self-hosted, with no data collection.
- **Lightweight:** a native client and server instead of a browser engine.
- **Open development:** extensible, and built in the open with community contributions.

## Getting Started

- **Testing HayChat?** Read the [tester guide](docs/tester-guide.md): download the client,
  connect, and report problems.
- **Running a server?** Follow [deploy/README.md](deploy/README.md) to run the server image with
  PostgreSQL under podman, then [give yourself the admin
  role](deploy/README.md#first-time-setup).
- **Developing?** Install [podman](https://podman.io/) and run:

  ```sh
  ./dev.sh ci              # build the toolchain image and run every check
  ./dev.sh up              # start PostgreSQL and a dev server
  ./dev.sh client alice    # open a client window as "alice"
  ```

  [docs/development.md](docs/development.md) explains the dev environment, and
  [CONTRIBUTING.md](CONTRIBUTING.md) how to contribute.

## Documentation

| Document | Contents |
| --- | --- |
| [User guide](docs/user-guide.md) | Every screen and control of the client |
| [Client configuration](docs/client-configuration.md) | `config.json` location and keys |
| [Deployment](deploy/README.md) | Server image, quadlet units, setup, backups, upgrades, releases |
| [Server configuration](docs/server-configuration.md) | Environment variables, migrations, status log |
| [Rooms and accounts](docs/rooms-and-accounts.md) | Server rules for accounts, rooms, admins, direct messages, unread counts |
| [Development](docs/development.md) | `./dev.sh`, checks, the dev pod, dependencies, CI |
| [Protocol](docs/protocol.md) | Transport encryption and protocol versions |

The full index, including the testing harness, voice tests, and design plans, is in
[docs/README.md](docs/README.md).

## Known Limitations

- Private rooms are not implemented: every account joins every room.
- Messages are encrypted in transit but not end-to-end; the server stores them in plain text.
- Sign-up is open and bans are per account, so a banned person can return with a new identity
  key. There is no account registration or way to move an account to another device.
- Voice has no echo cancellation or noise suppression: use headphones.
- Per-server settings (names, labels, per-user volumes and mutes) live in one client profile and
  are not synced between devices.
- Push-to-talk in other windows needs the GlobalShortcuts portal on Wayland; elsewhere on
  Wayland it works only while the HayChat window has focus.
- The admin account list has no search or paging.
- The Windows client is cross-compiled for releases and type-checked in CI, but has not yet been
  tested on a real Windows machine.

## License

HayChat is licensed under the AGPLv3 License. See the [LICENSE](LICENSE) file for more
information.

If you distribute modified versions of the software, you must also distribute the source code
under the same license. Using HayChat in a commercial product requires complying with the AGPLv3,
which may require releasing your own source code under the same license. Always make sure you
have the right to use and distribute any code you contribute under the AGPLv3.

**Modding.** If you sell a mod publicly, it must be dynamically linked: your mod can interact
with HayChat, but it cannot include the HayChat codebase. It should be a separate module that
communicates with HayChat through defined interfaces or APIs, so the core HayChat code remains
open while still allowing creative modifications and extensions.

**Third-party credits.** Release builds contain third-party code, libraries and fonts (the Odin
core library, `pg`, ENet, SDL3, SDL3_ttf, libopus, Inter and Twemoji).
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists what each release artifact contains, with
each licence, copyright line, and required credit; every archive ships it as
`THIRD_PARTY_NOTICES.txt` beside a `licenses/` folder.

## Contributing

Contributions are welcome! Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

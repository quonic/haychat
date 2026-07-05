# HayChat

![HayChat Logo](assets/icon.png)

HayChat is an alternative to Discord. It features end-to-end encryption, a responsive user interface, and a modular architecture for easy extensibility.

> [!IMPORTANT]
> HayChat is currently in early development and is not yet ready for production use. The project is open-source and welcomes contributions from the community.

## Features

- End-to-end encryption for secure communication
- Real-time messaging with low latency
- User-friendly interface with customizable themes
- Support for server chat in shared rooms, with direct messages planned for a later release
- Cross-platform compatibility (Windows, Linux, macOS(planned))
- Modular architecture for easy addition of new features
- Comprehensive testing suite for reliability

## Advantages over Discord

- Open-source and self-hosted, giving users full control over their data and privacy
- Lightweight and optimized for performance, reducing resource usage
- Focus on security and privacy, with end-to-end encryption and no data collection
- Customizable and extensible architecture, allowing users to tailor the application to their needs
- Transparent development process with community involvement and contributions

## Getting Started

Clone the repository and follow the instructions in the `client/` and `server/` directories to set up the development environment and run the application locally.

On Linux, the client stores its config at `XDG_CONFIG_HOME/haychat/config.json`, defaulting to `$HOME/.config/haychat/config.json` when `XDG_CONFIG_HOME` is unset. Startup also migrates the original historical malformed path formula `$HOME$XDG_CONFIG_HOME/haychat/config.json`, which means older installs are recovered from either the default `$HOME$HOME/.config/haychat/config.json` shape or a custom `XDG_CONFIG_HOME` variant if that file still exists.

### Development Environment Setup

The supported HC-201 bootstrap path is a Linux-first, source-based maintainer flow for Ubuntu/Debian hosts with `apt`. This matches the current internal tester handoff model: build from source, run PostgreSQL locally, run one HayChat server, and launch local clients against it.

1. Run `./setup-dev-env.sh` on a clean Ubuntu/Debian machine. The script installs the supported OS packages, builds Odin, prepares the required shared libraries, starts PostgreSQL, and provisions the default local database role/database used by HayChat.
   If you reuse an existing HayChat database instead of provisioning a fresh one, the configured role must own that database or have `USAGE, CREATE` on schema `public` before running the helper bootstrap.
2. Ensure `odin` is on your `PATH`. The bootstrap script links it into `$HOME/.local/bin/odin`; if your shell does not already include `$HOME/.local/bin`, add that directory before continuing.
3. Validate the supported source-build environment with `odin check server`, `odin check client -target:linux_amd64`, and `odin check client -target:windows_amd64`.
4. Use the server helper seam below to seed auth data and launch the local MVP runtime.

The supported bootstrap script assumes these defaults unless you override them before running it:

- PostgreSQL host: `localhost`
- PostgreSQL port: `5432`
- PostgreSQL user: `haychat`
- PostgreSQL password: `haychat`
- PostgreSQL database: `haychat`
- Odin root: `$HOME/Odin`
- Skald checkout: `$HOME/Skald`

Supported environment overrides for the bootstrap script:

- `HAYCHAT_DATABASE_URL`
- `HAYCHAT_DATABASE_PORT`
- `HAYCHAT_DATABASE_USER`
- `HAYCHAT_DATABASE_PASS`
- `HAYCHAT_DATABASE_NAME`
- `HAYCHAT_ODIN_ROOT`
- `HAYCHAT_SKALD_ROOT`
- `HAYCHAT_LOCAL_BIN_DIR`

### Local Test Server Bootstrap

The repository includes one supported helper path for the MVP auth flow. The helper script seeds deterministic test identities for the server's existing nickname lookup contract.

### Server Environment Configuration

A checked-in example server environment file is provided at `.env.example` for local tester runs.

1. Copy the example file with `cp .env.example .env`.
2. Load it into your shell with `source ./.env >/dev/null 2>&1`.
3. Adjust values only if your local PostgreSQL or runtime layout differs from the supported defaults.

Required baseline values for the supported local MVP flow:

- `HAYCHAT_DATABASE_URL`
- `HAYCHAT_DATABASE_PORT`
- `HAYCHAT_DATABASE_USER`
- `HAYCHAT_DATABASE_PASS`
- `HAYCHAT_DATABASE_NAME`

Optional server/runtime values documented in the example file:

- `HAYCHAT_WEB_ADMIN_PORT`
- `HAYCHAT_LISTEN_ADDR`
- `HAYCHAT_LISTEN_PORT`
- `HAYCHAT_LOG_LEVEL`
- `HAYCHAT_LOG_DIR`
- `HAYCHAT_FILE_STORAGE_PATH`
- `HAYCHAT_SERVER_IDENTITY_FILE`
- `HAYCHAT_MAX_RESTARTS`
- `HAYCHAT_RESTART_BACKOFF_MIN`
- `HAYCHAT_RESTART_BACKOFF_MAX`
- `HAYCHAT_MAX_NETWORK_THREADS`
- `HAYCHAT_MAX_FILE_SIZE`
- `HAYCHAT_MAX_STORAGE_CAPACITY`
- `HAYCHAT_SERVER_PRIVATE_KEY`
- `HAYCHAT_SERVER_PUBLIC_KEY`

Supported helper commands are exactly: `bootstrap`, `start`, `start-background`, `wait-ready [timeout_secs]`, `stop`, `bootstrap-start`, `bootstrap-start-background`, and `hc118-gate`.

Primary local MVP workflow:

1. Run `cp ./.env.example ./.env && source ./.env >/dev/null 2>&1`.
2. Run `./run-test-server.sh bootstrap-start-background` as the primary MVP start path.
3. Confirm readiness with `GET http://localhost:8080/status`.
4. Launch clients manually with `odin run client` in separate terminals.
5. Shut the helper-managed server down with `./run-test-server.sh stop`.

The helper owns only the server lifecycle. PostgreSQL remains a prerequisite, and clients are launched manually.

Companion and lower-level helper flows:

1. If your PostgreSQL setup differs from the supported defaults, load `.env` or export `HAYCHAT_DATABASE_URL`, `HAYCHAT_DATABASE_PORT`, `HAYCHAT_DATABASE_USER`, `HAYCHAT_DATABASE_PASS`, and `HAYCHAT_DATABASE_NAME` before running the helper.
2. Run `./run-test-server.sh bootstrap` to create the minimum `users` table and seed the test identities.
3. Run `./run-test-server.sh start` to launch the server in the foreground, or `./run-test-server.sh bootstrap-start` to bootstrap and launch in one step.
4. For the Linux-first local confidence gate, use `./run-test-server.sh start-background` and then `./run-test-server.sh wait-ready` before running live client proofs. Shut the helper-managed server down with `./run-test-server.sh stop` when the proof completes or fails.
5. `./run-test-server.sh bootstrap-start-background` performs bootstrap, background startup, readiness waiting, and cleanup-safe lifecycle ownership through the same helper seam.
6. `./run-test-server.sh hc118-gate` is the supported Linux-first validation gate. It runs `odin test common`, `odin test server`, `odin test client`, then the live startup/connect/auth/message proof with phase-labeled output. The gate bootstraps the local database before starting the server, so the configured database user must own the target database or have `USAGE, CREATE` on schema `public` in that database.

Running `odin run server` directly now uses tester-safe local runtime paths by default, resolved relative to the server process working directory: logs in `./logs`, file storage in `./storage`, and the server identity file at `./storage/server_identity.json`. `HAYCHAT_LOG_DIR`, `HAYCHAT_FILE_STORAGE_PATH`, and `HAYCHAT_SERVER_IDENTITY_FILE` still override those defaults.

Seeded test identities:

- `hayseed` resolves to user ID `1`
- `haypeer` resolves to user ID `2`

The bootstrap SQL lives in `server/sql/auth_bootstrap.sql` and is safe to rerun. It keeps those seeded nickname-to-user-ID mappings deterministic without requiring testers to write SQL by hand.

## License

HayChat is licensed under the AGPLv3 License. See the [LICENSE](LICENSE) file for more information.

Remember that if you distribute modified versions of the software, you must also distribute the source code and include the same license. Always ensure you have the right to use and distribute any code you contribute under the AGPLv3 License.

If a user wants to use HayChat in a commercial product, they would need to comply with the AGPLv3 License terms, which may require them to release their own source code under the same license if they distribute the software. This is a key aspect of the AGPLv3 License, which promotes open-source software and ensures that derivative works also remain open-source.

### Modding

If you sell a mod publicly, it must be dynamically linked. This means that you can create a mod that interacts with HayChat, but you cannot include the entire HayChat codebase in your mod. Instead, your mod should be a separate module that communicates with HayChat through defined interfaces or APIs. This allows for greater flexibility and ensures that the core HayChat code remains open and accessible to the community while still allowing for creative modifications and extensions.

## Contributing

Contributions are welcome! Please read the contributing guidelines in the `CONTRIBUTING.md` file for more information on how to contribute to the project.

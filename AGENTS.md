# Agents.md

## Project Status - Unreleased

Making breaking changes to the project is currently allowed, but it is recommended to avoid doing so unless necessary. If breaking changes are made, they should be clearly documented in the commit messages and in the documentation to ensure that users are aware of the changes and can update their code accordingly. It is important to maintain clear communication with users and contributors about any changes that may affect them, especially if those changes are breaking.

## Odin Programming Language

- Overview of the language: <https://odin-lang.org/docs/overview/>
- Base Library Collection: `$HOME/Odin/base`
- Core Library Collection: `$HOME/Odin/core`
- Vendor Library Collection: `$HOME/Odin/vendor`
- Shared Library Collection: `$HOME/Odin/shared`
- SDL3 bindings: `$HOME/Odin/vendor/sdl3` (SDL3_ttf bindings in `$HOME/Odin/vendor/sdl3/ttf`)
- GitHub Repository: <https://github.com/odin-lang/Odin>

### Language Quirks

- Variable declarations follow the syntax `name: type = value`, where the type can be inferred from the value if it is not explicitly specified. For example, `x := 5` will infer that `x` is of type `int`, while `y: f32 = 3.14` explicitly declares that `y` is of type `f32`. If the type cannot be inferred from the value, it must be explicitly declared to avoid compilation errors.
- For getting the length of an array, use `len(array)`. This includes strings, slices, and other array-like structures.

## Project Structure

- `client/`: Contains the client-side code for the HayChat application, including the GUI and client logic.
- `server/`: Contains the server-side code for the HayChat application, including the web service frontend, database management, and client-server communication.
- `common/`: Contains shared code and definitions used by both the client and server.
- `deploy/`: Production server image (`deploy/Containerfile`), quadlet units, SQL helpers, and the release archive script used by `.forgejo/workflows/release.yml`. See `deploy/README.md`; `./dev.sh release-image --smoke` builds and smoke-tests the image.

## Code Style

- Tabs are used for indentation, with a standard indentation level of 4 spaces.
- One True Brace Style is used for braces, with the opening brace on the same line as the control statement and the closing brace on a new line.
- Lines should not exceed 100 characters in length, and should be broken up into multiple lines if necessary.
- Variable and function names should be descriptive and use camelCase.
- In camelCase names, use "URL" (not "Url"), "API" (not "Api"), "ID" (not "Id"), and "HTTP" (not "Http").
- Constants should be in all uppercase letters with underscores separating words.
- Comments should be used to explain the purpose of code blocks and any complex logic, and should be written in English.

## Odin Checker

- Checking for compile errors for server component: `odin check server`
- Checking for compile errors for client component: `odin check client -target:windows_amd64` and `odin check client -target:linux_amd64` for Windows and Linux respectively.
- These need `odin` on `PATH`. Without a host toolchain, run them in the dev image: `./dev.sh check`, or `./dev.sh shell` for ad-hoc commands.

## Development Environment

- Development runs in podman containers through `./dev.sh` (`./dev.sh help` lists commands). The dev image (`dev/Containerfile`) holds Fedora 44, the system libraries, and the Odin toolchain pinned in `dev/bootstrap-odin.sh`; containers get a snapshot of the working tree, never the host's `logs/`, `storage/`, or `~/.config/haychat`.
- Package and pin changes go in `dev/install-packages.sh` and `dev/bootstrap-odin.sh`. Both the dev image and Forgejo CI (`.forgejo/workflows/ci.yml`) use them, and the image tag is a hash of those files.
- `./dev.sh up` / `restart` / `down` / `reset` manage the dev pod (PostgreSQL + server). `./dev.sh reset` deletes only the dev pod's volumes; no command touches the host's client config.
- The forge is Forgejo with a Linux-only runner. Windows is covered by `odin check client -target:windows_amd64` in `./check.sh`.

## Testing

- Test files: `*_test.odin` (e.g., `chat_test.odin`)
- Full gate (what CI runs): `./dev.sh ci`, which runs `./check.sh` and then `dev/live-proof.sh --all` (startup auth, two-client room chat, two-client direct message, in-process voice, headless harness, two-process voice, GUI automation, and server SQL proofs) against a throwaway PostgreSQL. `./dev.sh check` runs only `./check.sh`. Tests run with `ODIN_TEST_FAIL_ON_BAD_MEMORY`, so any leak or bad free fails the suite.
- Prefer component-scoped checks while editing: `odin test common`, `odin test client`, or `odin test server -define:ODIN_TEST_THREADS=1`. The serial server suite is the reliable default for router/database tests.
- Acting as a user: `client --headless` runs the client without a window, reading commands on stdin and printing JSON lines on stdout, so an agent or script can connect, list rooms, send, and wait for events. See `docs/testing-harness.md`; `./dev.sh live --harness` runs its smoke test against a throwaway server.
- Voice as a user: the harness's `voice-*` commands join voice, send a tone or file (`voice-source`), record into a raw F32LE mono 48 kHz file (`voice-sink`, `voice-flush`) and report counters (`voice-stats`), with `voice_status` and `voice_speaking` events; `dev/tools/voice-check` checks a recording for a tone with the client's Goertzel analysis (`client/toneanalysis`). `./dev.sh live --voice` runs `dev/voice-proof.sh`: two client processes, a 440 Hz tone through the server, checked by `voice-check` and the counters, then the same through SDL's disk audio driver, through injected loss, and one voice session per user (two profiles sharing one identity key with different `device_id` values: the second join takes voice over). See "Voice" in `docs/testing-harness.md`.
- Driving the real window: `client --ui-script FILE` runs the GUI from a script (click by drawn text or widget ID, type, keys, wait for text, BMP screenshots) by pushing synthetic SDL events, with no OS input injection; `SDL_VIDEO_DRIVER=offscreen` needs no display. See "GUI Automation" in `docs/testing-harness.md`; `./dev.sh live --ui` runs `dev/ui-smoke.sh` (GUI alice and headless bob chat and exchange a DM, then admin alice creates a room and joins, mutes and leaves voice on SDL's dummy audio driver).
- Use the built-in testing library from Odin. `import "core:testing"` and any procedures must have `t: ^testing.T,` as the first parameter.
- Use `assert(a == VALUE, "message that test failed")` for assertions in tests, and provide a clear message that indicates what the expected value was and what the actual value is if the assertion fails.

## Architecture

- Client GUI: a small immediate-mode UI toolkit in `client/ui`, drawn with `vendor:sdl3` (SDL_Renderer) and `vendor:sdl3/ttf` (text). Screens in `client/view.odin` call `State_*` action procedures directly.
- Server Web Service Frontend: `shared:odin-http`, repository: <https://github.com/laytan/odin-http>
- Database: `shared:pg` bindings for libpq version 17, repository: <https://github.com/laytan/odin-postgresql>
- Client-Server Communication: `vendor:ENet` bindings for enet

## Chat Protocol And Ownership

- Shared encrypted application packets and database IPC types belong in `common/protocol.odin`. When changing a wire payload, update both client transport decoding and server routing, then validate `odin test common` before component tests.
- Room access is server-authoritative and membership-scoped. Rooms are open for now: new accounts join every room and new rooms include every account, but `room_members` stays the authoritative check. Clients may request room lists and history, but must treat `ServerListRooms`, membership, edit, and delete events as the source of truth for visible rooms.
- Room management (create, rename, delete) is admin-only and checked by the server per request. `ServerAuthSuccess.isAdmin` (protocol 8) only tells the client which controls to show; a role change reaches the client on its next connection.
- Direct messages are server-authoritative too: a client must not append a sent direct message locally but wait for the `ServerDirectMessage` echo, which carries the stored ID and timestamp and reaches every session of both users. Direct history pages exactly like room history. `ServerUserList` and `ServerUserPresence` are the source of truth for who exists and who is online.
- Voice frames (`ClientVoiceFrame`, `ServerVoiceFrame`) are binary, never CBOR: `common/voice_wire.odin` encodes them into caller buffers and decodes them without allocating, sealed in voice datagrams (`sealVoiceDatagram`/`openVoiceDatagram`) on ENet channel 2. A decoded `opus` slice borrows its input buffer and is valid only while that buffer is; copy it to keep it. The voice AAD (`makeVoiceAAD`) is the control AAD plus the datagram's kind byte and is never used for control packets. Voice control (`ClientJoinVoice` … `ServerVoiceLeft`, protocol 10) is ordinary CBOR on the control channel; `ServerVoiceParticipants.recipientJoined` (protocol 12) is set per recipient session and is the only join acknowledgement, because participants carry user IDs, not sessions, with `*_deinit` helpers in `common/protocol.odin` for its owned strings and arrays. `ClientVoiceData`/`ServerVoiceData` are retired placeholders that are never sent and stay only to keep later wire values.
- One voice session per user (protocol 13, Q2): the server keeps at most one voice session per account, so a participant list names each user once. A join the user asked for takes voice over from the account's other session, which gets `ServerVoiceLeft{"joined voice on another device"}`; the client's automatic re-join after a reconnect (`ClientJoinVoicePayload.rejoin`) replaces only a session with the same `deviceId` and is otherwise refused with "voice is active on another device". `deviceId` is the profile's `device_id` config key, 32 lowercase hex characters (`common/voice_device.odin`); the server refuses a join without a valid one but keeps the session. A decoded `ClientJoinVoicePayload` owns `deviceId` (`ClientJoinVoicePayload_deinit`).
- Read state is server-authoritative too (protocol 11): the server keeps a read marker per account and room and per account and direct conversation, and `ServerListRooms`, `ServerDirectConversations`, and `ServerReadMarker` carry the marker and unread count. A client counts live messages from others between those, never lowers a count itself, and marks a conversation read only while the user is viewing it (`client/read_state.odin`); the server fans `ServerReadMarker` out to every session of the account. The unread rules are in `server/AGENTS.md`.
- `MessageType` numbers its members automatically. `common/protocol_test.odin` pins the wire value of every member in use; never renumber, add new members at the end of the enum, pin each member you put on the wire, and bump `protocolVersion` for any payload or enum change.
- The database schema changes only through migrations: append the next version to `DATABASE_MIGRATIONS` in `server/database_migrations.odin` and never edit one that has merged. The server migrates at startup and never drops tables; it refuses a database it cannot migrate. See "Schema Migrations" in `server/AGENTS.md`.
- Chat history uses message IDs as stable pagination cursors. Fetch the newest page with cursor `0`, request older pages with the oldest loaded message ID, and merge duplicate page boundaries by message ID.
- CBOR-decoded strings and dynamic arrays are owned allocations. Transfer ownership explicitly between packet/event/message layers, clear the source after transfer, and free ignored payloads. Do not retain borrowed decoded data after its packet or event is deinitialized.

## Security

- Use appropriate data types that limit exposure of sensitive information
- Never commit secrets or API keys to repository
- Use environment variables for sensitive data
- Validate all user inputs on both client and server
- Follow principle of least privilege for database access and other resources

## Configuration

When adding new configuration options, update all relevant places:

- `config.odin` for the new configuration option
- `config_test.odin` for tests related to the new configuration option
- Documentation to include the new configuration option and its purpose
- Any relevant code that uses the new configuration option should be updated to handle it appropriately
- Ensure that the new configuration option is properly validated and has appropriate default values if necessary
- If the new configuration option is sensitive (e.g., API keys, secrets), ensure that it is not hardcoded in the codebase and is instead loaded from environment variables or secure vaults
- Documentation in README.md

All configuration keys use consistent naming and MUST be documented.

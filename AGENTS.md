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
- Full gate (what CI runs): `./dev.sh ci`, which runs `./check.sh` and then `dev/live-proof.sh --all` (startup auth and two-client room chat proofs) against a throwaway PostgreSQL. `./dev.sh check` runs only `./check.sh`. Tests run with `ODIN_TEST_FAIL_ON_BAD_MEMORY`, so any leak or bad free fails the suite.
- Prefer component-scoped checks while editing: `odin test common`, `odin test client`, or `odin test server -define:ODIN_TEST_THREADS=1`. The serial server suite is the reliable default for router/database tests.
- Acting as a user: `client --headless` runs the client without a window, reading commands on stdin and printing JSON lines on stdout, so an agent or script can connect, list rooms, send, and wait for events. See `docs/testing-harness.md`; `./dev.sh live --harness` runs its smoke test against a throwaway server.
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
- `MessageType` numbers its members automatically. `common/protocol_test.odin` pins the wire value of every member in use; never renumber, add new members at the end of the enum, pin each member you put on the wire, and bump `protocolVersion` for any payload or enum change.
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

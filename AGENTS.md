# HayChat Project

HayChat is an open-source project that is designed to be a replacement for Discord, with a focus on privacy, security, performance, and self-hosting. The project is built using a monolithic architecture, which allows for greater control over the codebase and easier maintenance. The project is written in Odin, a programming language that is a general-purpose programming language with distinct typing built for high performance, modern systems and data-oriented programming.

## Odin Programming Language

- Overview of the language: <https://odin-lang.org/docs/overview/>
- Base Library Collection: <https://pkg.odin-lang.org/base/>
- Core Library Collection: <https://pkg.odin-lang.org/core/>
- Vendor Library Collection: <https://pkg.odin-lang.org/vendor/>
- GitHub Repository: <https://github.com/odin-lang/Odin>

### Language Quirks

- When assigning values to a struct, Odin expects either names or no names, but not a mix of both. For example, `return return Message{id = getNextMessageID(), type = type, timestamp = time.now(), pid = pid}` is valid, while `return Message{getNextMessageID(), type, timestamp = time.now(), pid}` is not valid and will result in a compilation error. Value assignments are always in the form of `field = value` when using named fields, and all fields must be assigned in the same way (either all named or all unnamed) to avoid syntax errors.
- Odin variable declarations follow the syntax `name: type = value`, where the type can be inferred from the value if it is not explicitly specified. For example, `x := 5` will infer that `x` is of type `int`, while `y: f32 = 3.14` explicitly declares that `y` is of type `f32`. If the type cannot be inferred from the value, it must be explicitly declared to avoid compilation errors.

## Project Structure

- `client/`: Contains the client-side code for the HayChat application, including the GUI and client logic.
- `server/`: Contains the server-side code for the HayChat application, including the web service frontend, database management, and client-server communication.
- `common/`: Contains shared code and definitions used by both the client and server.

## Build & Commands

`.` is the root directory of the project, and it can be replaced with the relative path to a specific subdirectory if you want to run the commands in that context.

- Typecheck: `odin check .`
- Test: `odin test .`
- Build: `odin build .`
- Run: `odin run .`
- Documentation Generation: `odin doc .`

### Development Environment

TODO: Add instructions for setting up a development environment, including any necessary tools and dependencies.

## Code Style

- Tabs are used for indentation, with a standard indentation level of 4 spaces.
- One True Brace Style is used for braces, with the opening brace on the same line as the control statement and the closing brace on a new line.
- Lines should not exceed 100 characters in length, and should be broken up into multiple lines if necessary.
- Variable and function names should be descriptive and use camelCase.
- In camelCase names, use "URL" (not "Url"), "API" (not "Api"), "ID" (not "Id"), and "HTTP" (not "Http").
- Constants should be in all uppercase letters with underscores separating words.
- Comments should be used to explain the purpose of code blocks and any complex logic, and should be written in English.

## Testing

- Test files: `*_test.odin` (e.g., `chat_test.odin`)
- Test command: `odin test .`
- Use the built-in testing library from Odin. `import "core:testing"` and any procedures must have `t: ^testing.T,` as the first parameter.
- Use `assert(a == VALUE, "message that test failed")` for assertions in tests, and provide a clear message that indicates what the expected value was and what the actual value is if the assertion fails.

## Architecture

- Client GUI: `vendor:raylib` bindings for raylib version 5.5
- Server Web Service Frontend: `shared:odin-http`, repository: <https://github.com/laytan/odin-http>
- Database: `shared:pg` bindings for libpq version 17, repository: <https://github.com/laytan/odin-postgresql>
- Client-Server Communication: `vendor:ENet` bindings for enet

## Security

- Use appropriate data types that limit exposure of sensitive information
- Never commit secrets or API keys to repository
- Use environment variables for sensitive data
- Validate all user inputs on both client and server
- Follow principle of least privilege for database access and other resources

### Cryptography

HayChat uses a dual-key system for separate authentication and encryption:

- **Encryption**: `core:crypto/ecdh` (X25519) for key exchange, `core:crypto/hkdf` (HKDF-SHA256) for key derivation, and `core:crypto/aes` (AES-256-GCM) for authenticated symmetric encryption
- **Authentication**: `core:crypto/ed25519` for digital signatures (signing/verifying messages)

Each user has two key pairs:

1. **Authentication key pair** (ed25519): Used to sign messages and prove identity
2. **Encryption key pair** (ECDH X25519): Used for key exchange to establish encrypted communication channels

**Key Exchange Flow**:

1. Parties exchange their ECDH public keys
2. Each party performs ECDH with their private key and the other's public key to derive a shared secret
3. The shared secret is passed through HKDF-SHA256 to derive a 32-byte AES-256 key
4. Messages are encrypted with AES-256-GCM using the derived key

**Authentication Flow**:

1. Server sends a random nonce challenge
2. Client signs the nonce with their ed25519 private key
3. Server verifies the signature using the client's ed25519 public key
4. No passwords are needed - possession of the private key proves identity

**Best Practices**:

- Always use `deriveEncryptionKey()` instead of raw ECDH to ensure proper key derivation
- Use `defer clearKey()` and `defer mem.zero_slice()` to clean up sensitive key material
- Never reuse IVs - `encrypt()` generates a fresh random IV for each message
- Include session ID and message type in AAD to prevent replay attacks
- Separate authentication from encryption to prevent key misuse

- The server will be responsible for managing user accounts, handling authentication, and storing data in the database. The client will be responsible for rendering the user interface and communicating with the server to send and receive data.

## Git Workflow

- ALWAYS run `odin check .` before committing code to ensure that there are no syntax errors or type errors in the codebase.
- ALWAYS run `odin test .` before committing code to ensure that all tests are passing and that new code does not introduce any regressions.
- NEVER use `git push --force` on the main branch
- Use `git push --force-with-lease` for feature branches if needed
- Always verify current branch before force operations

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

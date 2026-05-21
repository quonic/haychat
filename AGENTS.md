# Agents.md

## Project Status - Unreleased

Making breaking changes to the project is currently allowed, but it is recommended to avoid doing so unless necessary. If breaking changes are made, they should be clearly documented in the commit messages and in the documentation to ensure that users are aware of the changes and can update their code accordingly. It is important to maintain clear communication with users and contributors about any changes that may affect them, especially if those changes are breaking.

## Odin Programming Language

- Overview of the language: <https://odin-lang.org/docs/overview/>
- Base Library Collection: `$HOME/Odin/base`
- Core Library Collection: `$HOME/Odin/core`
- Vendor Library Collection: `$HOME/Odin/vendor`
- Shared Library Collection: `$HOME/Odin/shared`
- Skald GUI Framework: `$HOME/Odin/shared/skald`
- GitHub Repository: <https://github.com/odin-lang/Odin>

### Language Quirks

- When assigning values to a struct, Odin expects either names or no names, but not a mix of both. For example, `return Message{id = getNextMessageID(), type = type, timestamp = time.now(), pid = pid}` and `return Message{getNextMessageID(), type, time.now(), pid}` are valid, while `return Message{getNextMessageID(), type, timestamp = time.now(), pid}` is not valid and will result in a compilation error.
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

## Testing

- Test files: `*_test.odin` (e.g., `chat_test.odin`)
- Test command: `odin test .`
- Use the built-in testing library from Odin. `import "core:testing"` and any procedures must have `t: ^testing.T,` as the first parameter.
- Use `assert(a == VALUE, "message that test failed")` for assertions in tests, and provide a clear message that indicates what the expected value was and what the actual value is if the assertion fails.

## Architecture

- Client GUI: `shared:skald` an Elm-architecture GUI framework with immediate-mode-level performance, repository: <https://github.com/BuLEEto/Skald>
- Server Web Service Frontend: `shared:odin-http`, repository: <https://github.com/laytan/odin-http>
- Database: `shared:pg` bindings for libpq version 17, repository: <https://github.com/laytan/odin-postgresql>
- Client-Server Communication: `vendor:ENet` bindings for enet

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

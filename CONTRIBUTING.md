# Contributing to HayChat

We welcome contributions to HayChat! Please follow these guidelines to ensure a smooth contribution process.

## Getting Started

1. Fork the repository on Forgejo and create a new branch for your changes.
2. Install podman. `./dev.sh` builds the toolchain image and runs everything in containers (see the Development Environment section of `README.md`).
3. Follow the project's code style and conventions (see below).
4. Write tests for your changes using the built-in Odin testing framework.
5. Run `./dev.sh ci`. It runs the compile checks (including the Windows client), every test suite, and the live server/client proof, and a test fails on any memory leak or bad free. Forgejo CI runs the same steps on every pull request.
6. While iterating, `./dev.sh check` skips the live proof. Inside `./dev.sh shell`, or on a host with `odin`, scope checks to one component: `odin test common`, `odin test client`, or `odin test server -define:ODIN_TEST_THREADS=1`.
7. Commit with clear, descriptive messages and push to your fork.
8. Create a pull request against the main branch.

## Code Style

- Use meaningful variable and function names in camelCase. Types should be in PascalCase.
- Use tabs for indentation, with a standard indentation level of 4 spaces.
- Follow One True Brace Style for braces.
- Write concise comments explaining complex logic.
- Keep code well-organized and modular.
- Maintain performance, especially in critical sections.
- Write comprehensive tests covering typical use cases and edge cases.
- Avoid unnecessary dependencies and bloat.
- Keep lines under 100 characters or a reasonable length.

## Pull Requests

- Use a clear, descriptive title summarizing your changes.
- Explain your motivation and include relevant context.
- Keep PRs focused—split large changes into separate PRs if needed.
- For bug fixes, describe the issue and how it's resolved.
- For UI changes, include screenshots or a demo video.
- For new features, add documentation explaining the functionality.
- Be responsive to feedback and ready to make requested changes.

## License

By contributing, you agree your work will be licensed under the AGPLv3 License. Ensure you have the right to license any code you contribute under the AGPLv3 License.

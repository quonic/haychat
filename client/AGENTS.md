# HayChat Client Agents Documentation

## Build & Commands

- Typecheck: `odin check ./client`
- Test: `odin test ./client`
- Build: `odin build ./client`
- Run: `odin run ./client`
- Documentation Generation: `odin doc ./client`
- To take a screenshot of the client window when it starts up (for testing purposes), run `odin run ./client -define:TEST_SCREENSHOT=true` and it will take a screenshot after the first frame is rendered and save it in the current directory with the name `haychat_screenshot.png`.

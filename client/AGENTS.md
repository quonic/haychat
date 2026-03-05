# HayChat Client Agents Documentation

## Build & Commands

- Typecheck: `cd client && odin check ./client`
- Test: `cd client && odin test ./client`
- Build: `cd client && odin build ./client`
- Run: `cd client && odin run ./client`
- To take a screenshot of the client window when it starts up (for testing purposes), run `cd client && odin run ./client -define:TEST_SCREENSHOT=true` and it will take a screenshot after the first frame is rendered and save it in the current directory with the name `haychat_screenshot.png`.

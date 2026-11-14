# HayChat Documentation

## Using HayChat

| Document | For |
| --- | --- |
| [tester-guide.md](tester-guide.md) | Testers: getting the client, connecting, what to try, and reporting problems |
| [user-guide.md](user-guide.md) | Every screen and control of the client: settings, server settings, connection status, context menus, voice, and administration |
| [client-configuration.md](client-configuration.md) | The client's `config.json`: where it lives and every key |

## Running a Server

| Document | For |
| --- | --- |
| [deploy/README.md](../deploy/README.md) | Running a server for real users: the server image, quadlet units, first-time setup, firewall, backups, upgrades, and release builds |
| [server-configuration.md](server-configuration.md) | Every `HAYCHAT_*` environment variable, startup exit status, schema migrations, and the `[Status]` log line |
| [rooms-and-accounts.md](rooms-and-accounts.md) | The rules the server enforces for accounts, display names, rooms, admin actions, direct messages, and unread counts |

## Developing HayChat

| Document | For |
| --- | --- |
| [development.md](development.md) | The podman dev environment (`./dev.sh`), checks, the dev pod, client dependencies, and CI |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | How to contribute: branches, code style, pull requests |
| [AGENTS.md](../AGENTS.md), [client/AGENTS.md](../client/AGENTS.md), [server/AGENTS.md](../server/AGENTS.md) | Project conventions and component internals, written for coding agents and useful to anyone changing the code |
| [protocol.md](protocol.md) | Transport encryption and what each protocol version added |
| [server-networking.md](server-networking.md) | The server's threads, IPC queues, and network loop |
| [testing-harness.md](testing-harness.md) | The headless client (`client --headless`), voice test commands, and GUI automation (`client --ui-script`) |
| [voice-manual-test.md](voice-manual-test.md) | Measuring voice on real audio devices with PipeWire, and the Windows voice checklist |
| [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) | Third-party code, libraries and fonts in each release artifact, with their licences |

## Plans and History

[plan/](plan/) holds design documents and the plans of past work rounds. They record decisions
and their reasons at the time they were written and are not kept up to date; the documents above
describe the current state.

| Document | Contents |
| --- | --- |
| [plan/2026-10-assessment.md](plan/2026-10-assessment.md) | Codebase assessment, October 2026 |
| [plan/2026-11-05-user-testing-readiness.md](plan/2026-11-05-user-testing-readiness.md) | Readiness plan for the first tester round |
| [plan/voice-rooms-design.md](plan/voice-rooms-design.md) | Voice rooms design (audio, codec, wire format, relay) |
| [plan/2026-11-05-after-first-testers.md](plan/2026-11-05-after-first-testers.md) | Work after the first tester round: migrations, read state, voice |
| [plan/2026-11-14-admin-settings-menus.md](plan/2026-11-14-admin-settings-menus.md) | Admin interface, per-server settings, and context menus |

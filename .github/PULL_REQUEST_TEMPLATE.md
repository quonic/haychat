<!--
Thanks for contributing. HayChat is developed on Forgejo
(https://git.spyingwind.com/quonic/haychat), where CI runs; a pull request opened there gets
checked and reviewed sooner. CONTRIBUTING.md has the details; delete the parts that do not
apply. Forgejo uses .forgejo/PULL_REQUEST_TEMPLATE.md; keep the two in step.
-->

## Summary

<!-- What does this change and why? Link the Forgejo or GitHub issue it fixes. -->

Closes #

## Changes

-

## Testing

- [ ] `./dev.sh ci` passes locally (CI does not run on GitHub)
- [ ] New or changed behaviour has tests (`*_test.odin`), and a live proof where it needs a server
- [ ] UI changes: screenshots or a short video below

<!-- How you checked it by hand, if you did: which client, server, platform. -->

## Compatibility

- [ ] Wire change: `protocolVersion` bumped, new `MessageType` members added at the end and pinned
      in `common/protocol_test.odin`, client decoding and server routing both updated
- [ ] Schema change: a new migration appended to `DATABASE_MIGRATIONS`, none edited
- [ ] New configuration: documented in `docs/client-configuration.md` or
      `docs/server-configuration.md` (and `.env.example`)
- [ ] Breaking change: described below and in the commit message
- [ ] None of the above

## Documentation

- [ ] The documents that describe the changed behaviour are updated (`docs/README.md` lists
      them), or nothing user-visible changed

<!--
Thanks for contributing. CONTRIBUTING.md has the details; delete the parts that do not apply.
GitHub uses .github/PULL_REQUEST_TEMPLATE.md; keep the two in step.
-->

## Summary

<!-- What does this change and why? -->

Closes #

## Changes

-

## Testing

- [ ] `./dev.sh ci` passes (Forgejo CI runs the same steps on this pull request)
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

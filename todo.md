# TODO

- [ ] Replace placeholder admin responses with live data (peer snapshot, logs, worker load).
- [ ] Harden shutdown/restart semantics with explicit stop tokens and bounded request timeouts in web admin handlers.
- [x] Add request IDs to DatabaseQuery/DatabaseQueryResult/DatabaseError for strict correlation under concurrency.
- [ ] Replace string-command parsing with structured packet decoding (CBOR/protocol type) in main routing.
  - [ ] Message versioning protocol
  - [ ] Max packet size limits
  - [ ] Deterministic encoding flags (recommend ENCODE_SMALL)
  - [ ] Client legacy support (if needed later)
  - [ ] Update client send path to emit common. Packet CBOR for the three new request types.
  - [ ] Add integration tests that send encoded packets through network IPC and assert typed CBOR responses.
  - [ ] Add temporary compatibility shim only if you want a transition window for old clients.

- [ ] Add tests for the new main-thread router handlers (auth/store/db command parsing and response routing).

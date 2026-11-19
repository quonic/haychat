# HayChat: roles and permissions, then registration (#43) (2026-11-18)

`main` is at protocol 22 and schema migration 10. Issue #43 ("Implement or retire
ClientRegister") was decided **Implement** (maintainer comment, 2026-11-18) with three sign-up
methods: self registration, invite codes, and invite codes plus approval, where invite codes
can grant roles and restrict a new account to one room. That needs roles and permissions the
server does not have yet (it knows one role, `admin`), so this round lands them first
(maintainer decision 2026-11-18) and builds registration on top.

Read this whole file, `AGENTS.md`, `client/AGENTS.md` and `server/AGENTS.md` before starting a
package. Protocol and migration numbers below are placeholders: each package takes the next
free number when it merges.

## Goals

1. **Roles and server permissions.** Admins create named roles from a fixed set of permissions
   defined in code, assign them to accounts, and see them in the Admin section. `admin` stays
   the built-in role that holds every permission.
2. **Room permissions.** Per-room grants for everyone and per role (who may send, speak and
   manage members), and a new room access mode whose members are the holders of given roles.
3. **Registration modes.** A server-wide mode, **Open**, **Invite only** or **Invite +
   approval**, stored in the database and changed live by an admin.
4. **Invite codes.** Created by accounts with the Create invites permission. Admins can also
   attach roles, restrict the new account to one room, and waive approval.
5. **Approval.** In Invite + approval mode a sign-up with a valid code becomes a request with a
   written reason, which an account with Approve registrations accepts or declines.
6. **Retire the placeholders.** `ClientRegister`/`ServerRegisterResponse` get real payloads,
   and the unused role messages and the `Role` struct go away (the role half of #33).

Out of scope: delegating kick, ban and rename to non-admins (that needs a role hierarchy, see
Later), more than one device per account (#86), moving an account to another key (#42), and
removing banned accounts from encrypted rooms (#72).

## Decisions

| #   | Decision |
| --- | --- |
| D1  | Server permissions are a fixed `common.ServerPermission` enum carried as a `bit_set` (u64) on the wire and as `server_roles.permissions BIGINT` in the database. Its wire values are pinned like `MessageType`'s. There are no custom permission names. |
| D2  | R1's permissions: `ManageRooms` (create, edit and delete rooms), `ManageRoomMembers` (add and remove members in invite rooms), `CreateInvites`, `ApproveRegistrations`. Admins also hold `ManageRoles`, `ManageRegistration`, and kick/ban/rename, which stay admin-only and are never assignable. None of the delegated permissions acts on an account, so no role hierarchy is needed. |
| D3  | `admin` is a built-in role (`server_roles.builtin`): it cannot be renamed, deleted or given fewer permissions. Every existing guard (no self-revoke, never the last admin, no kick or ban of an admin) stays keyed to it. Only admins create, edit, delete and assign roles. |
| D4  | The server checks every permission in the same SQL statement as the change, as it does now for `admin`. A permission held through roles is the union of the account's roles' bits; admin implies every bit. |
| D5  | Room permissions are allow-only, with no denies: `rooms.everyone_permissions` (default Send + Speak) OR `room_role_permissions(room_id, role_id, permissions)` for the account's roles. Admins hold every room permission. Membership (`room_members`) still decides who sees a room at all. |
| D6  | New `RoomAccess.Role` (value 4): members are the accounts holding any of the room's `room_access_roles`. Granting or revoking a role adds or removes those memberships in the same statement. Encrypted rooms cannot use it, because adds must be signed in the member log. |
| D7  | The registration mode lives in a one-row `server_settings` table, migrated as **Open** so upgrades change nothing. Only admins change it (`ClientAdminSetRegistrationMode`). `deploy/sql/set-registration-mode.sql` lets an operator change it without a client. |
| D8  | Invite codes work in every mode: in Open mode they still grant roles or a room. In Invite + approval mode every code needs approval unless an admin created it with **Skip approval**. |
| D9  | A code is 20 random bytes shown as grouped Crockford base32 (`XXXX-XXXX-…`), returned once when it is created and never again. The server stores only `sha256(code)`. A code has an optional expiry, an optional use limit, a note, and can be revoked. A use is counted when a sign-up or a request is accepted, and a declined request does not give it back. |
| D10 | Non-admin inviters create plain codes only (no roles, room or skip approval), with an expiry of at most 7 days, and see and revoke only their own codes. Admins see and revoke every code, and only admins attach roles (never `admin` itself) or a room. |
| D11 | **Restricted accounts** (`users.restricted`): an account created through a room code joins only that room. It never joins Public rooms automatically (sign-up, a new Public room, a switch to Public, or the default room). Only admins and holders of that room's `ManageRoomMembers` may add it elsewhere, and an admin can lift the restriction. A room code cannot target an encrypted room in this round, because the server cannot sign the log's Add. |
| D12 | The invite code never travels in plaintext. An unknown key on a server that is not Open, or a client that asks to register (`ClientAuthRequestPayload.registering`), gets the new plaintext handshake message `ServerRegistrationRequired{mode, status, message}`. Both sides then activate transport exactly as on `ServerAuthSuccess`. The session enters a registering state where the only encrypted packets accepted are `ClientRegister` and `Ping`. |
| D13 | `ClientRegister{inviteCode, reason}` (wire value 14, now encrypted) gets `ServerRegisterResponse{status: Created\|Pending\|Refused, message, auth}` (wire value 15). On Created, `auth` carries the `ServerAuthSuccess` fields and the session becomes authenticated without a new handshake. A session gets 5 attempts and 10 minutes before it is disconnected. |
| D14 | A pending request (`registration_requests`, one per key) keeps the requested name, the reason (1–500 characters) and the code. Approval does not create the account: the next sign-in of that key creates it through the normal identity statement, with the code's grants and whatever display name the client sends then, so a name taken in the meantime is the same "name in use" refusal as today. A still-connected applicant is completed live when approved. A decline shows its reason on the next attempt. |
| D15 | Bootstrap: the `HAYCHAT_ADMIN_PUBLIC_KEY` key may always create or claim its account, in any mode. `deploy/sql/create-invite.sql` prints a code for an operator who has no admin yet. |
| D16 | The client treats `Refused` and a declined request like a ban: shown and not retried until the user asks. `Pending` shows a waiting screen with **Check again**. |
| D17 | **Restricted accounts see and DM only accounts they share a room with** (maintainer, #43, 2026-11-18). This holds in both directions: a direct message involving a restricted account needs a shared room, or the other side must be an admin, checked in the DM statements. `ServerUserList`, `ServerUserPresence` and `ServerUserUpdated` are filtered per recipient by the same rule, and admins and approvers always see everyone. When a membership change alters visibility, the affected sessions get a fresh `ServerUserList`. Existing DM history stays readable after the last shared room is gone, but new messages are refused. |
| D18 | **Approvers get a badge only, with no pop-up** (maintainer, #43). It shows the count of pending requests on the Admin section and on Sign-up requests. The count is fetched after sign-in by accounts with `ApproveRegistrations`, and `ServerRegistrationRequestUpdated` keeps it current. |
| D19 | **Invite links** (maintainer, #43): `haychat://host:port/invite/CODE?key=SERVER_PUBLIC_KEY_HEX`, built by the client next to the code when it is created. The link carries the server's identity key, so the client pins it and the code only ever goes to that server. A link whose key differs from an existing pin for that address is refused. Opening a link never signs up on its own: the client shows the server and asks the user first. The current hand-off between client processes, a fixed `/tmp/haychat_url_handler` file, must not carry a code. G2 replaces it with a file in the per-user runtime or config directory, created with mode 0600 and deleted once read. |

## Packages

### R1: Roles and server permissions (#95; protocol +1, migration +1)

- **Schema:** `server_roles` gains `permissions BIGINT NOT NULL DEFAULT 0`, `builtin BOOLEAN`,
  and `position INT` (display order only). The migration marks `admin` builtin and gives it
  every bit.
- **Common:** add `ServerPermission`/`ServerPermissions` with pinned values, and add `RoleSummary
  {id, name, permissions, builtin, position}`. `UserSummary` gains `roleIds`. `ServerAuthSuccess`
  and `ServerAccountUpdated` gain `permissions` (the effective set; `isAdmin` stays).
- **Messages:** `ClientAdminListRoles`/`ServerRoleList`, `ClientAdminSaveRole` (create or edit),
  `ClientAdminDeleteRole`, `ClientAdminSetUserRoles` (every non-builtin role of one account;
  `ClientAdminSetRole` keeps doing admin), and the fan-outs `ServerRoleUpdated`/`ServerRoleDeleted`
  to every session. A changed effective set sends `ServerAccountUpdated` to the affected sessions.
- **Server:** `server/database_roles.odin` holds the SQL guards. Today's `sr.name = 'admin'` checks
  for room management and member management (`database_room_access.odin`, `database.odin`) move
  to a shared permission subquery for `ManageRooms`/`ManageRoomMembers`. Kick, ban and rename keep
  checking `admin`.
- **Retire:** `ClientGetRoles` … `ServerRemovedRole`, the `Role` struct and
  `ClientAuthRequestPayload.roles`. The wire values stay retired and pinned as unused.
- **Client:** a Roles page in the Admin section (list, create, edit the permission checkboxes,
  delete), roles on the account list and the member context menu, and controls gated on
  `permissions` rather than only `isAdmin`.
- **Tests:** database tests for each guard (non-admin cannot save roles, builtin admin cannot be
  changed, permission union), router fan-out tests, the protocol pins, and `admin-proof.sh` gains
  a role that lets bob create a room.

### R2: Room permissions and role rooms (#96; protocol +1, migration +1)

- **Schema:** `rooms.everyone_permissions`, `room_role_permissions`, `room_access_roles`, and the
  `RoomAccess.Role` value.
- **Room permissions:** `SendMessages`, `SpeakInVoice`, `ManageMembers`, `EditRoom`.
  `RoomSummary` gains `myPermissions` (computed per recipient) and, for managers, the grants. The
  post, voice-join and member statements check them. In voice, "may not speak" means the relay
  drops that session's frames; it does not refuse the join.
- **Messages:** `ClientAdminSetRoomPermissions{roomId, everyone, roles[]}`. Any change resends
  `ServerListRooms` to the affected sessions, because `myPermissions` changes.
- **Role rooms:** `ClientAdminSetUserRoles` and role deletion add and remove `room_members` in the
  same statement and send `ServerRoomMembershipChanged`, so the read marker and history rules
  for joining and leaving apply unchanged.
- **Encrypted rooms:** room permissions apply (the server refuses to store a sealed message from
  a member without Send), `RoomAccess.Role` is refused, and the server's 5.1 add rule becomes
  "ManageMembers in the room, or a member of a Member invite room", still plus the log signature.
- **Client:** a Permissions page on the room admin screen, and the composer and push-to-talk
  disabled with a reason when the room grants no Send or Speak.

### G1: Registration on the server (protocol +1, migration +1)

- **Schema:** `server_settings(registration_mode)`, `invites`, `invite_roles`,
  `registration_requests`, `users.restricted`, and `users.invite_id` (for auditing who came in
  through which code).
- **Identity statement:** `DATABASE_RESOLVE_USER_IDENTITY_SQL` gains the mode check, the
  approved-request path (D14), and the admin key's bootstrap path (D15). It skips the
  Public-room join for restricted accounts. The Public-room statements (create Public, switch to
  Public, default room) also skip restricted accounts.
- **Register statement:** `DATABASE_REGISTER_SQL` runs as one statement: hash match, not revoked
  or expired, uses left, the mode and the code's skip-approval flag, then either insert the account
  with its roles, `restricted` and the code's room (or the Public rooms), or insert a pending
  request, and increment the use count.
- **Router:** add `ServerRegistrationRequired`, the registering session state and its gate in
  `MainRouterState_handleEncryptedPacket`, the attempt and time limits (D13), and a cap on how
  many sessions may be registering at once. `ServerRegisterResponse` moves out of the plaintext
  handshake list (`server/main.odin` near line 290).
- **Messages:** `ClientAdminSetRegistrationMode`; `ClientCreateInvite`/`ServerInviteCreated` (the
  only time the code appears); `ClientListInvites`/`ServerInviteList`; `ClientRevokeInvite`;
  `ClientListRegistrationRequests`/`ServerRegistrationRequests`; `ClientDecideRegistration{id,
  approve, reason}`; `ServerRegistrationRequestUpdated` to every approver session; and
  `ClientAdminSetRestricted`. `UserSummary` gains `isRestricted`.
- **Restricted visibility (D17):** DM send and history statements check for a shared room or an
  admin on the other side. The user list, presence and user-updated broadcasts are filtered per
  recipient, and room membership changes that involve a restricted account resend
  `ServerUserList` to the sessions whose view changed.
- **Deploy:** add `deploy/sql/create-invite.sql` and `set-registration-mode.sql`, and update the
  bootstrap section of `deploy/README.md`.

### G2: Registration in the client and harness

- **Transport:** handle `ServerRegistrationRequired` (activate transport, raise a
  registration-needed event) and `ServerRegisterResponse` (Created joins the normal connected
  path, without a second activation). Add the Pending, Refused and Declined connection states,
  none of them auto-retried.
- **Sign-in UI:** an invite code field with paste and trimming of spaces and dashes, a reason
  field in approval mode, the waiting screen with **Check again**, and a server setting **Use an
  invite code** that sets `registering` for Open servers.
- **Admin UI:** the registration mode picker; an Invites page (create with expiry, uses, note,
  and for admins roles, room and skip approval; the code shown once with Copy; list and
  revoke); Sign-up requests with a badge (D18, no pop-up) and approve or decline with a reason;
  and lifting Restricted on the account list.
- **Invite links (D19):** **Copy link** next to the code. `schemeHandler` learns the `invite`
  path and `key` query and moves its hand-off file out of `/tmp` (0600, deleted once read).
  `client/main.odin`'s TODO for scheme joins is finished for both `join` and `invite`: add or
  match the server entry and pin, show a confirmation, then connect with `registering` set and
  the code filled in.
- **Restricted accounts:** the DM list and the user picker show only what `ServerUserList`
  sends. A DM whose send is refused shows "You no longer share a room with this person".
- **Headless:** commands `register CODE [REASON]`, `invite-create …`, `invite-list`,
  `invite-revoke ID`, `registration-list`, `registration-decide ID approve|decline [REASON]`,
  `registration-mode open|invite|approval`, and `roles-*` from R1. Events `registration_required`,
  `registration_result`, `registration_request` and `invite_created`.

### G3: Proofs and documentation

- **Proof:** `dev/registration-proof.sh`, run as `./dev.sh live --registration` and added to
  `dev/live-proof.sh --all`. Admin alice switches to Invite only; carol without a code is told to
  register and cannot chat; a code from inviter bob signs carol up; an expired or revoked code
  is refused; approval mode makes dave pending, alice approves, and dave is completed live; a
  room code makes erin restricted and not in `#general`; erin sees only that room's members and
  cannot DM carol until both share a room; and the admin key bootstraps in Invite only mode on a
  fresh database.
- **Link tests:** client tests for parsing `haychat://…/invite/…` (bad key, a key that
  differs from the pin, malformed code) and for the hand-off file's mode and deletion.
- **GUI smoke:** `ui-smoke.sh` creates an invite, checks the Sign-up requests badge, and
  approves a request through the GUI.
- **Docs:** `docs/rooms-and-accounts.md` (Accounts and Identity, new Roles, Registration and
  Restricted accounts sections, and the Known Limitations line), `docs/protocol.md`,
  `docs/user-guide.md`, `docs/testing-harness.md`, `docs/server-configuration.md` (a pointer to
  the mode helper), `deploy/README.md`, the README's Known Limitations, and the "Chat Protocol
  And Ownership" bullets in `AGENTS.md`, `client/AGENTS.md` and `server/AGENTS.md`. Note in the
  admin D4 text that closed sign-up now answers "a banned person can come back with a new key".

## Order

R1 (#95) → R2 (#96) → G1 → G2 → G3 (#43). R2 and G1 touch different tables and could run in parallel after R1,
but both edit the identity statement and the Public-room statements, so landing them in sequence
avoids a hard merge. G2 can start on a branch against G1's protocol once G1's wire types are
merged.

## Validation per Package

`odin test common`, `odin test server -define:ODIN_TEST_THREADS=1`, and `odin test client`
while editing, then `./dev.sh ci` before merge (the gate includes `admin-proof.sh` and, from G3
on, `registration-proof.sh`).

## Later

- A role hierarchy (`server_roles.position` acting on accounts), so kick, ban and rename can be
  delegated.
- Invite codes for encrypted rooms: a manager's client signs the Add when the new account first
  connects.
- A per-IP registration rate limit, if a single session's limits prove too weak.

## Follow-ups After G3 (2026-11-18)

Collected from the PRs of R1 (#97), R2 (#98), G1 (#99), G2 (#100) and G3, after #43 closed.
Done in G3 and so not listed: the GUI roles step (R1), **I have an invite code** on the
first-run and add-server form (G2), and wiping `sealPacketForSession`'s CBOR buffers (G2).

- **New accounts appear as presence stubs.** A new account reaches other sessions only as
  `ServerUserPresence`, so their directories lack its `isRestricted` and identity key until
  their next `ServerUserList`: an admin sees no Restricted badge or Lift restriction for a new
  room-code account until they sign in again. The server could send `ServerUserUpdated` with
  the full `UserSummary` (through `MainRouterState_sendAboutUser`) when it creates an account.
  Found by `dev/registration-proof.sh` (G3).
- **D17 side channels** (G1): `ClientFetchUserKeys`, the direct conversation mark-read refusal,
  and voice participant names in a shared room still tell a restricted account that another
  account exists by its ID.
- **A restricted account in a room made Public** (G1) gets no fresh `ServerUserList` when the
  switch changes that room's members.
- **Per-IP sign-up limit** (G1, Later): only the per-session limits (5 answers, 10 minutes) and
  the 64 concurrent registering sessions exist.
- **Ping has no reply** anywhere (G1).
- **Sign-up requests in the GUI** (G2) list pending requests and those decided while the screen
  was open; older decided ones only through the harness's `registration-list all`.
- **An invite link's registering flag** (G2) is lost if a settings change rebuilds the transport
  before the user signs up.
- **The `instance` file** (G2) is overwritten by a second plain GUI start, and the first
  window's exit removes it; the next link then opens a second window.
- **Windows link hand-off** (G2) compiles but is untested at runtime, and
  `registerSchemeHandler*` still builds its shell commands wrongly (older than G2).
- **CBOR growth buffers** (G3): `sealPacketForSession` wipes the final buffers, but copies that
  `cbor.marshal` outgrew while encoding are freed unwiped; a wiping allocator would close it.
- **Room permissions page** (R2) is not pushed another manager's change; it refreshes when it is
  opened again. The Admin section's room list could gain a **Permissions…** button (R2).
- **The Admin section's room list** (R1, older) does not refresh by itself when another admin
  changes a room the admin is not in.
- **Later** (unchanged): a role hierarchy so kick, ban and rename can be delegated, invite codes
  for encrypted rooms (a manager's client signs the Add), and the per-IP limit above.

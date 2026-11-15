# Rooms and Accounts

The rules the server enforces for accounts, rooms, admins, direct messages and read state. The
server is authoritative for all of them; clients only show what it reports. How these look in
the client is in the [user guide](user-guide.md).

## Accounts and Identity

An account is its client identity key; the nickname is only its current name. There are no
passwords and no registration step (`ClientRegister` is not implemented): the first time a key
connects, the server creates an account under the client's display name, or, for a keyless
fixture account such as `haypeer`, binds the key to it. Keyless accounts that hold a server role,
such as the fixture's `admin`, can be claimed only by `HAYCHAT_ADMIN_PUBLIC_KEY` (see
[server-configuration.md](server-configuration.md#runtime)).

The server lists every account with an online flag (online while at least one of its sessions is
authenticated) and tells connected sessions when an account comes online or goes offline. Every
account sees which accounts are admins and which are banned; banned accounts stay listed because
history names them.

### Display Names

When the same key connects with a different display name, the server renames that account in
place: same user ID, same rooms, same direct messages. The rename succeeds only while no other
account holds the new name; otherwise the login is refused and the client says the name is
already in use. The old name is then free for anyone.

- Connected users learn the new name at once, through the same notice used for presence.
- Messages a client has already loaded keep the name they were sent with until it fetches that
  history again: the server reads each sender's current name when history is requested.
- A renamed account does not join any rooms it was not already in.
- The server logs `[Main] User N renamed from "old-name" on peer P` for each rename.
- While an admin has locked the account's name (see below), sign-in keeps the locked name
  whatever the client asks for.

A display name can only change through the client's own key or an admin's rename; there is no
way to move an account to another device or key.

## Rooms

Membership is stored per account in `room_members`, which the server checks for every send,
history request, member list and voice join. Who may join a room is its **access mode**
(`rooms.access`, protocol 15, schema migration 4), chosen by the admin who creates it:

| Mode | Who is a member | Who can add members | Who can remove members |
| --- | --- | --- | --- |
| **Public** | Every account: new accounts join it, and a new Public room includes everyone | Nobody needs to (adds are refused: "Public rooms include every account") | Admins |
| **Member invite** | Whoever has been added | Any member, and admins | Admins |
| **Admin invite** | Whoever has been added | Admins only | Admins |

- In every mode, any member can leave a non-public room (`ClientLeaveRoom`); a Public room
  cannot be left ("You cannot leave a public room"). Admins can rename, edit and delete every
  room, also one they are not in.
- Members cannot remove each other, also in a Member invite room: the server would have to
  remember who invited whom.
- A non-public room is listed only for its members; anyone else is refused its history and its
  member list ("Not a room member"), whether or not it exists. Members and admins can fetch a
  room's members (`ClientFetchRoomMembers`).
- **Creating a room without joining it.** An admin who clears **Join this room** creates an
  invite room they are not a member of: they do not see its messages, but they still add and
  remove its members, edit and delete it, through the Admin section's list of every room
  (`ClientAdminListRooms`). A Public room always includes its creator.
- **Changing the mode.** An admin may switch a room between any two modes. Switching to Public
  adds every account in the same statement (each is told it joined); switching away from Public
  keeps every member.
- Every rule is checked in the database, in the same statement as the change, so a role or
  membership change between a check and the write cannot slip through.
- Existing rooms became Public with full history when the server migrated to schema 4, so
  nothing changed for them. An account removed from a Public room stays removed across
  reconnects; only accounts created later join it automatically.

**History for new members** (`rooms.history_visibility`) is chosen at creation and fixed
afterwards:

- **From join** (the form's default for invite rooms): a member reads only messages sent after
  they were added (`room_members.joined_at`); the server serves no older history to them, and
  their unread count starts at the same point. Someone who is removed and later added again
  counts as new from the second addition: a removal or leave also drops their read marker for
  the room.
- **Full history:** a new member reads everything the room has.
- **Public rooms always have full history**, whatever was chosen. A room created Public stores
  Full; a From join room that is made Public shows everyone everything while it stays Public.

### Encrypted Rooms

An admin may make a Member invite or Admin invite room **encrypted** when creating it (protocol
18, schema migration 7; the form checks **Encrypt this room** by default for invite rooms). A
Public room cannot be encrypted, and the choice never changes afterwards. For now an encrypted
room takes no messages and no voice ("Encrypted room messages arrive in a later update"): its
end-to-end encrypted messages arrive with the next part of the encryption work, so nothing
readable is ever stored in one.

What an encrypted room adds is a **signed member list**. The server's `room_members` still
decides who may send and read history, but the clients decide who the room's keys will go to,
from a log of membership changes that each change's author signs (see
[protocol.md](protocol.md#encrypted-rooms-and-the-member-log-protocol-18)). Three roles meet in
an encrypted room:

| Role | Who | What they can do |
| --- | --- | --- |
| **Member** | Whoever the log added and has not removed (at most 100) | Read and, later, write messages; leave; in a Member invite room, add people |
| **Manager** | Named by the log: the admins the creator kept checked when creating the room (the creator always), and anyone a manager made a manager later | Add and remove members and managers, switch the room between Member invite and Admin invite (also needs the admin role). A manager who is not a member reads nothing |
| **Admin** | Holds the server's admin role | Remove members (the server writes the removal into the log itself), rename, edit and delete the room. An admin who is not a manager cannot add anyone: "Only this room's managers can add members; ask <names>" |

- **An add needs both** the server's permission (an admin, or a member of a Member invite room)
  and a valid signature by someone the log allows. A manager who loses the admin role stays a
  manager until another manager removes them, but the server no longer accepts their adds.
- The last manager cannot be removed while the room has members.
- `ClientAddRoomMember` and `ClientLeaveRoom` are refused for encrypted rooms ("This room is
  encrypted: its members change through its member list"); the client signs log entries
  instead. An admin's removal (`ClientRemoveRoomMember`) still works: the server writes an
  unsigned Remove into the log.
- Every verified change shows in the room as an event line ("alice added carol", "the server
  removed dave", "erin (manager) added themselves"), so every addition is visible to every
  member.
- A client that finds the log changed behind its back (an entry without a valid signature, a
  rewritten entry it verified before, a shorter log than it saw, or a key that does not match
  its pin) shows "This room's member list was changed on the server" on the room and its
  Members page and signs nothing more for that room.
- Creating an encrypted room without joining it works as for any invite room: the admin
  manages it from the Admin section and its Members page.

**The default room.** On startup, a server whose `rooms` table is empty creates `#general`
("General discussion", room ID `1` on a new database), makes every existing account a member, and
logs `Created default room #general`. Once any room exists it creates nothing, so an admin who
renames or deletes `#general` keeps that change across restarts, as long as another room
remains. A room the server creates has no creator (`rooms.created_by_user_id` is `NULL`).

**Room types.** A room takes text, voice, or both; existing rooms and new rooms default to both.
A voice-only room refuses chat messages, a text-only room refuses voice joins ("voice is disabled
in this room"), and making a room text-only removes everyone from its voice.

**History** is paged by message ID: the newest page is fetched with cursor `0`, older pages with
the oldest loaded message ID. Room management (create, rename, delete) is admin-only; deleting a
room removes its history.

## Admin Actions

An admin is an account holding the `admin` server role. The server checks the role and the rules
below in the database for every request, in the same statement as the change.

- **Role:** an admin can grant and revoke the admin role. The account's connected sessions learn
  it at once and show or hide the admin controls without reconnecting. Nobody can revoke their
  own role, and the server always keeps at least one admin. A role changed directly in the
  database (`deploy/sql/make-admin.sql`) reaches the client only on its next sign-in, though the
  server enforces it at once.
- **Rename:** an admin can rename an account and lock its name. While it is locked, the account
  signs in under that name whatever display name its client asks for, so the next connection does
  not undo the rename. An admin can unlock it again, after which the client's display name wins
  on its next sign-in.
- **Kick:** ends every session of an account. Its client tells the user and does not reconnect by
  itself until the user presses **Retry now**. Admins cannot kick themselves or another admin
  (revoke the role first).
- **Ban and unban:** a ban ends every session of the account and refuses its sign-in ("This
  account is banned from this server", with the admin's reason); its client does not retry. The
  same rules as for a kick apply. An unban lets the account sign in again. Bans are per account,
  and sign-up is open, so a banned person can connect again with a new identity key as a new
  account.

## Direct Messages

Any two accounts on a server can message each other directly. Direct messages belong to that one
server: they are stored in its `direct_messages` table, survive restarts, and are paged like room
history. Since protocol 17 they are end-to-end encrypted whenever both sides can: the server
stores an envelope it cannot open, and verifies its signature against both accounts' identity
keys before it does. A message to someone who cannot receive encrypted messages goes out only
through **Send without encryption**; it is signed, and the server can read it, like every message
from before protocol 17 (see [protocol.md](protocol.md#encrypted-direct-messages-protocol-17)
and the [user guide](user-guide.md#encrypted-direct-messages)). A sent message is delivered to
every connected session of both the sender and the recipient; a client shows its own message
only when the server echoes it back with the stored ID and timestamp.

## Unread Counts

The server keeps one read marker per account and room and per account and direct conversation,
holding the newest message ID that account has read. Unread counts therefore survive a client
restart and follow the account to every device. The server stops counting at 100.

- In a room, unread means messages from other people after your marker. Before you have read a
  room at all, it means the messages from others that arrived after you joined it, so a new
  account or a new room starts with nothing unread.
- In a direct conversation, unread means the other person's messages after your marker; before
  you have read it, every message from them.
- Your own messages never count.
- The client marks the conversation you are looking at (selected, with the window focused) read
  up to its newest loaded message, when you open it and as new messages arrive, at most once per
  second. The server then tells every connected session of your account.

A server upgraded to read state (schema migration 2) starts with nothing unread: the migration
gives every existing room member and both sides of every existing conversation a marker at the
newest message.

## Known Limitations

- Rooms are not end-to-end encrypted yet: access modes decide whom the server lets read a room,
  not who can technically read it (the server and its operator can read every unencrypted
  room). Encrypted rooms have their signed member list but take no messages until the next
  part of the encryption work.
- Bans and account changes do not remove anyone from encrypted rooms' member lists by
  themselves; an admin removes them from each room.
- The Admin section's room list does not refresh by itself when another admin changes a room
  the admin is not in; reopening Server settings fetches it again.
- The Admin section lists every account of the server at once, with no search or paging.
- Bans are per account and sign-up is open; closed sign-up (#43) is the fix.
- Account registration (`ClientRegister`) is not implemented.
- Room messages are not end-to-end encrypted, and direct messages only when both sides can (see
  [protocol.md](protocol.md)). The server sees who writes to whom and when.

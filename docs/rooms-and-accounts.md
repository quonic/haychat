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

Rooms are open: every account is a member of every room. A nickname that connects for the first
time joins every existing room, and a new room includes every account, so testers can chat as
soon as they connect. Membership is still stored per account in `room_members`, which the server
checks for every send and history request; that is where private rooms will plug in. Accounts
that already existed keep the memberships they had, so a `ClientRemoveRoomMember` lasts across
reconnects. The client has no member management: `ClientAddRoomMember` and
`ClientRemoveRoomMember` stay in the protocol for private rooms later, and the client never sends
them.

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
history. Like room chat, they are encrypted in transit to the server but not end-to-end, so the
server and its operator can read them. A sent message is delivered to every connected session of
both the sender and the recipient; a client shows its own message only when the server echoes it
back with the stored ID and timestamp.

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

- Private rooms are not implemented: every account joins every room.
- The Admin section lists every account of the server at once, with no search or paging.
- Bans are per account and sign-up is open; closed sign-up (#43) is the fix.
- Account registration (`ClientRegister`) is not implemented.
- Messages are not end-to-end encrypted (see [protocol.md](protocol.md)).

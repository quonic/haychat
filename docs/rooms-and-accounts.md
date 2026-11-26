# Rooms and Accounts

The rules the server enforces for accounts, sign-up, roles, rooms, admins, direct messages and
read state. The
server is authoritative for all of them; clients only show what it reports. How these look in
the client is in the [user guide](user-guide.md).

## Accounts and Identity

An account is its client identity key; the nickname is only its current name. There are no
passwords. How a new key gets an account depends on the server's
[registration mode](#registration): on an **Open** server (the default) the first time a key
connects, the server creates an account under the client's display name, or, for a keyless
fixture account such as `haypeer`, binds the key to it. On an **Invite only** or **Invite +
approval** server a new key has to sign up with an invite code first. A key that already has an
account always signs in, whatever the mode. Keyless accounts that hold a server role, such as
the fixture's `admin`, can be claimed only by `HAYCHAT_ADMIN_PUBLIC_KEY` (see
[server-configuration.md](server-configuration.md#runtime)), which may also always sign up.

The server lists every account with an online flag (online while at least one of its sessions is
authenticated) and tells connected sessions when an account comes online or goes offline. Every
account sees which accounts are admins and which are banned, and (protocol 23) which roles each
account holds; banned accounts stay listed because history names them. A
[restricted account](#restricted-accounts) sees, and is seen by, fewer accounts.

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
| **Public** | Every account: new accounts join it, and a new Public room includes everyone | Nobody needs to (adds are refused: "Public rooms include every account") | Room member managers |
| **Member invite** | Whoever has been added | Any member, and room member managers | Room member managers |
| **Admin invite** | Whoever has been added | Room member managers only | Room member managers |
| **Roles** (protocol 24) | Exactly the accounts holding one of the room's access roles | Nobody: giving someone an access role adds them | Nobody: taking the role away removes them |

"Room member managers" are admins, accounts holding a role with **Manage room members**, and
(protocol 24) members the room grants **Manage members**; "room managers" are admins and
accounts holding a role with **Manage rooms** (see [Roles and Permissions](#roles-and-permissions)
and [Room Permissions](#room-permissions)).

- In every mode, any member can leave a non-public room (`ClientLeaveRoom`); a Public room
  cannot be left ("You cannot leave a public room"). Room managers can create, rename, edit and
  delete every room, also one they are not in; anyone else is refused ("Room management
  permission required").
- Members cannot remove each other, also in a Member invite room: the server would have to
  remember who invited whom.
- A non-public room is listed only for its members; anyone else is refused its history and its
  member list ("Not a room member"), whether or not it exists. Members and admins can fetch a
  room's members (`ClientFetchRoomMembers`).
- **Creating a room without joining it.** An admin who clears **Join this room** creates an
  invite room they are not a member of: they do not see its messages, but they still add and
  remove its members, edit and delete it, through the Admin section's list of every room
  (`ClientAdminListRooms`). A Public room always includes its creator. Since protocol 31 that
  list (for every room manager) follows other managers' changes at once: the server tells room
  managers of every room created, edited, deleted, joined or left and of every change of grants
  (`ServerAdminRoomChanged`), and the client fetches the list again; an open Permissions page
  takes the new grants unless it has unsaved changes.
- **Changing the mode.** An admin may switch a room between any two modes. Switching to Public
  adds every account in the same statement (each is told it joined); switching away from Public
  keeps every member.
- **Role rooms** (protocol 24, schema migration 12). A room in the **Roles** mode names one or
  more access roles (never the built-in admin role), and its members are exactly their holders.
  Creating one, switching a room to it or changing its access roles makes the members exactly
  the holders in the same statement; giving an account an access role, taking it away or
  deleting the role adds or removes the account in the same statement too. Everyone who joins
  or leaves is told at once, and joining and leaving follow the usual history and unread rules
  (a removal drops the read marker). Nobody adds, removes or leaves by hand ("This room's members
  come from its access roles"). Switching a Role room to another mode keeps its members and
  forgets its access roles. Encrypted rooms cannot be Role rooms ("Encrypted rooms cannot take
  their members from roles"), because their adds must be signed in the member list.
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
Public room cannot be encrypted, and the choice never changes afterwards. Since protocol 19
(schema migration 8) its messages are end-to-end encrypted with each sender's chain key, which
only the members its signed member list names receive (see
[protocol.md](protocol.md#sender-chains-in-encrypted-rooms-protocol-19)); the server refuses
plaintext there and never stores anything readable in one. It takes no voice yet.

What an encrypted room adds is a **signed member list**. The server's `room_members` still
decides who may send and read history, but the clients decide who the room's keys will go to,
from a log of membership changes that each change's author signs (see
[protocol.md](protocol.md#encrypted-rooms-and-the-member-log-protocol-18)). Three roles meet in
an encrypted room:

| Role | Who | What they can do |
| --- | --- | --- |
| **Member** | Whoever the log added and has not removed (at most 100) | Read and write messages (each sealed to the members of the current epoch); leave; in a Member invite room, add people |
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
- **Epochs.** Every log entry starts a new epoch, and the server accepts a message only in the
  current one ("Room key is out of date" otherwise; the client then sends it again with a new
  chain). So a removed member gets no key for anything sent after the removal, and an added
  member gets the chains of its first epoch on and none before (From join).
- **Full history in encrypted rooms** (protocol 20): the member who adds someone hands them
  every older room key it holds, and any member online answers the newcomer's requests for the
  rest, so the newcomer reads the room's earlier messages as members' clients come online. A
  message whose key no online member holds waits until one connects. The server stores these
  forwarded keys only for Full history rooms, and the clients check every one against the
  member list; forwarded keys give access, but every message is still verified against its
  real sender. From join encrypted rooms never forward anything.
- **Keys from a database row.** A row added to `room_members` behind the log lets the server
  serve that account the room's history and its envelopes, but the log does not name it, so no
  envelope has a wrap for it and no member's client re-seals a chain to it: it opens nothing.

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
  so on an Open server a banned person can connect again with a new identity key as a new
  account. Closing sign-up ([Invite only or Invite + approval](#registration), protocol 25)
  stops that: a new key then needs a code.

## Roles and Permissions

Since protocol 23 (schema migration 11, #95) a server has **roles**: named sets of permissions
that admins give to accounts. An account's permissions are the union of its roles' permissions.
The permissions are fixed in code; there are no custom ones.

| Permission | What it allows | Who can hold it |
| --- | --- | --- |
| **Manage rooms** | Create, edit and delete rooms (also encrypted ones: create and change their access) | Any role |
| **Manage room members** | Add and remove members of invite rooms, see every room in the Admin section | Any role |
| **Create invites** | Create invite codes (see [Registration](#registration)) | Any role |
| **Approve sign-ups** | Accept or decline sign-up requests, and see every account | Any role |
| Manage roles, Manage sign-up, Kick, Ban, Rename | Admin actions | The admin role only |

- `admin` is the **built-in role**. It holds every permission and cannot be renamed, deleted or
  given fewer permissions. Every admin guard stays keyed to it (nobody revokes their own admin
  role, the server keeps an admin, admins cannot be kicked or banned). It is given and taken
  with **Make admin** and **Remove admin** as before.
- Only admins create, edit, delete and assign roles. A role other than admin can hold only the
  four delegable permissions; kicking, banning and renaming stay with admins, because they act
  on accounts and would need a ranking of who may act on whom.
- A server keeps at most 32 roles. Role names are 3 to 32 characters and unique (`admin`
  included).
- The server checks every permission in the same statement as the change, so a role changed in
  between cannot slip through. Clients only use the permissions to decide which controls to
  show.
- Every account lists the roles. A created, edited or deleted role reaches every connected
  session at once, an account given or denied roles shows its new roles to everyone, and an
  account whose permissions changed learns its new set without reconnecting.

## Registration

Since protocol 25 (schema migration 13, #43) a server has a **registration mode**, which only
admins change (from the client, or `deploy/sql/set-registration-mode.sql`):

| Mode | A new key |
| --- | --- |
| **Open** (the default; upgraded servers start here) | Gets an account at once. A client may still ask for the sign-up screen (**I have an invite code**, **Use an invite code**, or an invite link) to use a code that gives roles or a room. |
| **Invite only** | Needs a valid invite code. |
| **Invite + approval** | Needs a valid invite code and a written reason (1 to 500 characters); that makes a **sign-up request**, which an account with Approve sign-ups accepts or declines. A code created with **Skip approval** signs up at once and needs no reason. |

- **Signing up** happens inside the encrypted session: a key without an account is told to
  sign up instead of being signed in, and only then sends its code, so the code never travels in
  plaintext. A session gets 5 attempts and 10 minutes. Every invalid code (unknown, revoked,
  expired or used up) gets the same "This invite code is not valid". The account takes the name
  the client signs in with; a name already in use is refused as at sign-in.
- **Invite codes** are 32 symbols (20 random bytes, shown as `XXXX-XXXX-…`; dashes, spaces and
  case do not matter). The server shows a code once, when it is made, and stores only its hash.
  A code has a note, an optional expiry, an optional use limit, and can be revoked. A use counts
  when a sign-up or a request is accepted; a declined request does not give it back.
- **Who makes codes:** holders of Create invites. Codes from accounts other than admins are
  plain (no roles, room or Skip approval), expire within 7 days, and at most 25 can be usable at
  once; those accounts list and revoke only their own. Admins list and revoke every code, and
  only admins attach roles (never `admin` itself), a room, or Skip approval. An operator without
  an admin yet prints a code with `deploy/sql/create-invite.sql`.
- **Invite links** carry the server's address, the code and the server's identity key:
  `haychat://HOST:PORT/invite/CODE?key=SERVER_KEY`. The client pins that key, so the code only
  ever goes to that server, and it refuses a link whose key differs from the one it already
  pinned for the address. Opening a link never signs up by itself; the client asks first.
- **Requests:** one per key. Approvers see a count of waiting requests as a badge (no pop-up)
  and approve or decline them, with an optional reason that the applicant is shown. Approval
  creates the account at the applicant's next sign-in, or at once while they are still waiting
  in the client, with the code's roles and room. A declined applicant sees the decision and its
  reason, and is not retried until they ask. A room code's request cannot be approved once its
  room is deleted, made Public or turned into a Role room ("The room this invite was for is no
  longer available"). If that happens after the approval, the applicant's sign-in makes no
  account: the server declines the request with the reason "The room this invite was for is no
  longer available; ask for a new invite".
- `HAYCHAT_ADMIN_PUBLIC_KEY` may always sign up, in every mode, unrestricted and without
  approval, so a fresh server can start closed.

## Restricted Accounts

An account that signs up with a **room code** (an admin's code for one unencrypted Member invite
or Admin invite room) is **restricted** to that room:

- It joins only that room (and the Role rooms of the code's roles), never Public rooms: not at
  sign-up, not when a room is created Public or made Public, and not as the default room.
- Only holders of Manage members in a room (admins included) can add it there ("Only a member
  manager can add this restricted account"), and the encrypted member log follows the same rule.
- It sees, and exchanges direct messages with, only accounts it shares a room with and admins;
  only those accounts, admins and approvers see it. The user list, presence, account changes and
  key changes are filtered that way for each recipient, and when a membership change alters who
  shares a room with it (including a room it is in made Public), the affected sessions get a
  fresh user list. A new account appears in other clients' lists with its Restricted badge at
  once. A direct message without a
  shared room is refused ("You no longer share a room with this person"); history from before
  stays readable.
- An admin can lift the restriction (**Lift restriction** in the Admin section), which joins the
  account to every Public room. A room code cannot target an encrypted room yet, because the
  server cannot sign the room's member list.
- An operator can restrict an account or lift its restriction with SQL:
  `deploy/sql/set-restricted.sql` (`psql -v account=NAME -v restricted=true|false`), which also
  joins a lifted account to every Public room, or a plain `UPDATE users SET restricted = ...`.
  No restart is needed (#116): a trigger (migration 18) notifies the running server, which
  applies the change exactly as it applies an admin's, so the account's sessions and everyone's
  user lists follow at once and a lifted account joins the Public rooms. The server reads the
  restricted accounts again whenever its listener reconnects to the database, so a change made
  while that connection was down is not lost. A plain `UPDATE` made while the server is stopped
  joins no Public rooms; the helper does.

## Room Permissions

Since protocol 24 (schema migration 12, #96) each room says what its members may do. The
permissions are allow-only: nothing denies one, and a member may do what the room's **Everyone**
grant or the grant of any of their roles allows. Membership still decides who sees a room at all.

| Room permission | What it allows | Everyone, by default |
| --- | --- | --- |
| **Send messages** | Post chat messages, plaintext or sealed | Yes |
| **Speak in voice** | Be heard in the room's voice; without it you join and listen, and the server drops your audio | Yes |
| **Manage members** | Add and remove members (not in Public or Role rooms) | No |
| **Edit room** | Change the name, description and type, and the room's permissions | No |
| **Attach files** | Upload files to the room and send them with messages, together with Send messages (protocol 27) | Yes |

- Server permissions count in every room, member or not: **Manage room members** gives Manage
  members, **Manage rooms** gives Edit room, and admins hold every room permission.
- **Edit room** does not cover the access mode, the access roles or encryption, and not deleting
  the room: those stay with **Manage rooms**.
- A room's permissions are changed by holders of Manage rooms or the room's Edit room, and no one
  can add or take away a bit they do not hold themselves (Manage rooms counts as holding Send
  messages, Speak in voice, Edit room and Attach files). Only roles other than admin get grants.
- A grant counts only while its holder is a member: a member who leaves keeps the role but loses
  what the room granted it.
- The server checks every permission in the same statement as the change (a post, a voice join,
  an add or a removal, an edit), sealed messages in encrypted rooms included. In an encrypted
  room, adding someone needs Manage members there (or membership of a Member invite room) as
  well as a valid signature in the member list.
- Every room list carries your own permissions in each room, and a change to a grant, a role or
  the admin role sends a fresh list to everyone it concerns at once, so composers and voice
  follow without a reconnect. A room that existed before the migration grants everyone Send
  messages and Speak in voice, so nothing changed for it. Schema migration 15 (protocol 27) gave
  every existing room's Everyone grant Attach files too, so files work everywhere until a
  manager takes it away.

## Attachments

Since protocol 27 a message, in a room or a direct conversation, can carry up to four files, with
or without text (`docs/plan/2026-11-19-file-attachments.md`; the wire format is in
[protocol.md](protocol.md#attachments), and how to attach and save files in the
[user guide](user-guide.md#files)). The client never opens, runs or previews a file.

- **Sending.** A file is uploaded to the conversation first and then named in the message, and
  the server binds it to that message in the statement that stores it. In a room this needs
  **Send messages** and **Attach files**, checked when the upload begins and again when the
  message is stored, so taking Attach files away also stops a file that was uploaded before; in
  a direct conversation, the same recipient rules as a message (a restricted account only to
  people it shares a room with). A file uploaded to one conversation cannot go to another, and
  a file goes with one message only. An encrypted room takes only encrypted files, and a
  plaintext room only plaintext ones.
- **Encryption.** In encrypted rooms and encrypted direct conversations the client encrypts the
  file before it uploads it, and the file's key, name and type travel inside the encrypted
  message: the server stores only ciphertext padded to a coarse size, and learns the sizes, how
  many files a message has, and who uploads and downloads them. In plaintext conversations the
  sender signs each file's hash, size, name and type with the message, so neither another
  account nor the server can swap a file. The direct message **Send without encryption** switch
  covers the files too.
- **Who may download.** Whoever may read the message may download its files: room members (in a
  From join room, only files of messages sent after they joined) and the two sides of a direct
  conversation (a restricted account keeps them after its shared rooms are gone, as it keeps
  the history). Admins have no way around that, as for history. A removed member cannot fetch
  more files; files already saved stay where they were saved. The uploader may download a file
  that is not on a message yet. The client checks every file against the message (hash, and
  for encrypted files every piece and the padding) before it keeps it, and otherwise deletes
  it: "This attachment was changed on the server".
- **Limits.** Per file (25 MiB by default), per account stored (1 GiB) and uploaded per hour
  (512 MiB), optionally for the whole server, and a free-disk reserve; see
  [server-configuration.md](server-configuration.md#attachments). The server announces the
  per-file limit and the account quota at sign-in, and the client refuses a file that cannot
  fit before it uploads; the server checks every limit again. An upload reserves its size
  when it begins, so two at once cannot overshoot the quota.
- **What is kept.** A file stays as long as its message. A file uploaded but never sent is
  deleted after `HAYCHAT_ATTACHMENT_PENDING_HOURS` (24 by default), a stalled upload after an
  hour without data, a cancelled one after an hour, and the files of a deleted room within an
  hour of the deletion (never before their upload is an hour old). An upload whose client quit or crashed is not resumed: the
  client uploads the file again. Accounts are never deleted, so their files are not either.

### Moderation

Since protocol 28 admins look after the server's storage and can remove any file
([protocol.md](protocol.md#attachment-moderation-protocol-28)). This is for admins only, like
kick and ban: no role permission grants it, and the server checks the admin role in the
statement that reads or changes. In the client: **Remove attachment…** in a file card's
right-click menu, and **Storage** and **Removed files** in Server settings after the Admin
section (see the [user guide](user-guide.md#removing-files-and-storage)).

- **Storage use.** An admin sees the bytes stored on the server, the configured capacity, the
  free space on the server's disk, and the 100 accounts that store the most, with their file
  counts. Removed files count toward nothing; uploads in progress count with the size they
  reserved.
- **Removing a file.** An admin may remove any finished file, including their own: the file is
  deleted from the server's disk, its message stays and shows "Attachment removed by an admin"
  where the file was, nobody can download it again, and it stops counting toward its owner's
  quota. A download in progress is cut off with the same sentence. The message's signature still
  verifies, because the server keeps everything the sender signed. An optional reason (at most
  500 bytes) is written to the server's log with the file, the admin and the owner.
- **The removal log** (protocol 29). Every removal is also kept in a log on the server, with its
  reason: when, whose file, which admin removed it (or "an operator" for a removal made with
  SQL), where (the room, or a direct message), and the file's name unless it was encrypted (the
  server never sees an encrypted file's name). Admins, and only admins, see it as **Removed
  files** in Server settings, newest first, with **Load more** for older removals. Entries are
  kept indefinitely; there are few, and each is small. A removal before protocol 29 is listed
  without a reason, which was only in the server's log then.
- **Who is told.** Everyone who may read the message hears of the removal at once: the room's
  members who may read it, or the two sides of a direct conversation, or for a file that was
  never sent, its owner.
- **Without a client.** An operator can list usage and remove a file with SQL
  (`deploy/sql/attachment-usage.sql`, `deploy/sql/remove-attachment.sql`, see
  [deploy/README.md](../deploy/README.md#attachment-storage-and-removing-files)). The file is
  then deleted by the server's hourly pass, and clients see the removal on their next history
  fetch. The removal log lists it as removed by an operator, with the reason the operator gave.

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

## Editing and Deleting Messages

Since protocol 30 (#76) the author of a room or direct message can edit and delete it, and an
admin can delete any room message. The server checks every request in the statement that makes
the change ([protocol.md](protocol.md#editing-and-deleting-messages-protocol-30)):

- Only the author edits or deletes a message, and only one they can still read: a member of the
  room (in a From join room, a message from after they joined) or one side of the direct
  conversation. The recipient of a direct message cannot delete it, and admins cannot touch
  direct messages.
- An edit needs what a new message there needs at the time: membership, **Send messages** and a
  room with chat (and in a direct conversation, a room shared with a restricted account). It
  changes the text only; the message keeps its files. A message takes at most 100 edits, with no
  time limit, and every version is kept for the history.
- A delete leaves a tombstone with the message's ID, so history and read markers stay as they
  were. The text, its edits and its files go (the files' downloads stop and the files are
  deleted); an admin's delete also lists the files in the removal log. A deleted message never
  counts as unread.
- Every author's edit and delete is signed, so the server cannot make one up. A client shows a
  deleted message as "Message deleted" when the author signed it, and as "Removed by the server"
  otherwise, which is what an admin's delete looks like.

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

- Only encrypted rooms are end-to-end encrypted. For every other room, access modes decide whom
  the server lets read it, not who can technically read it (the server and its operator can
  read every unencrypted room). In a Full history encrypted
  room a new member reads older messages only once a member who holds their keys is online.
- Bans and account changes do not remove anyone from encrypted rooms' member lists by
  themselves; an admin removes them from each room.
- The member counts in the Admin section's list of rooms leave out accounts that signed up since
  it was last fetched, until another change to the room or reopening Server settings.
- The Admin section lists every account of the server at once, with no search or paging.
- Bans are per account. On an Open server a banned person can come back with a new key; set the
  server to Invite only or Invite + approval to stop that.
- A few requests still tell a restricted account that another account exists by its ID (the key
  bundle fetch, a direct conversation's mark-read refusal, voice participant names in a shared
  room).
- There is no per-address limit on sign-up attempts, only the per-session one (5 attempts,
  10 minutes) and at most 64 sessions signing up at once.
- Roles do not rank accounts, so kick, ban and rename cannot be delegated. Room permissions
  only allow, never deny: a room cannot take something from a role another grant gives.
- Files are never previewed, and there is no download cache: each **Save…** downloads again. A
  direct message with files is not queued while the other person's key is being fetched; it
  stays in the draft. The server is not a backup of its files: a file whose row the server keeps
  but whose file is gone from its disk (a database restored without its blob directory) shows as
  unavailable to the first reader who tries it, and the server then marks it removed, as an
  admin removal would, so its card reads "Attachment removed by an admin" (the removal log says
  "File missing from storage", removed by an operator). While the blob directory looks absent or
  incomplete, or after 10 such marks in an hour, it marks nothing and the file only shows as
  unavailable ([protocol.md](protocol.md), Missing files).
- Room messages are end-to-end encrypted only in encrypted rooms, and direct messages only when
  both sides can (see [protocol.md](protocol.md)). The server sees who writes to whom and when.

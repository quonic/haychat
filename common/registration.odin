package common

import "core:crypto"
import "core:crypto/sha2"
import "core:strings"
import "core:unicode/utf8"

// Registration (protocol 25, #43 G1, plan docs/plan/2026-11-18-roles-and-registration.md
// D7-D17).
//
// The handshake (D12, D13): a client sends ClientHello, gets ServerHello and
// ServerAuthChallenge, and answers with ClientAuthRequest (registering set when it wants to
// sign up with a code on an Open server). When the key has no account and the server will not
// create one for it (the mode is not Open, or registering was set, and neither an approved
// request nor HAYCHAT_ADMIN_PUBLIC_KEY lets it in), the server answers with the plaintext
// ServerRegistrationRequired instead of ServerAuthSuccess. Both sides then activate the
// transport exactly as they would on ServerAuthSuccess, and the session is registering: the
// only encrypted packets the server accepts are ClientRegister and Ping (which it ignores).
// The invite code therefore never travels in plaintext. A registering session gets
// REGISTER_ATTEMPTS_MAX ClientRegister answers and REGISTER_SESSION_SECONDS before the server
// disconnects it, and at most REGISTERING_SESSIONS_MAX sessions may be registering at once.

// The server's registration mode (D7), server_settings.registration_mode. Pinned.
RegistrationMode :: enum u8 {
	Open           = 1, // Anyone may sign up; codes still grant roles or a room (D8)
	InviteOnly     = 2, // A valid invite code is needed
	InviteApproval = 3, // A valid code makes a request an approver accepts or declines
}

registrationModeIsSupported :: proc(mode: RegistrationMode) -> bool {
	return mode == .Open || mode == .InviteOnly || mode == .InviteApproval
}

// A sign-up request's state (registration_requests.status; None means no request). Pinned.
RegistrationRequestStatus :: enum u8 {
	None     = 0,
	Pending  = 1,
	Approved = 2,
	Declined = 3,
}

// How a ClientRegister ended (ServerRegisterResponse.status). Pinned.
RegisterStatus :: enum u8 {
	Created  = 0,
	Pending  = 1,
	Refused  = 2,
	Declined = 3,
}

// Invite codes (D9): INVITE_CODE_BYTES random bytes from the system CSPRNG, shown as grouped
// Crockford base32 (formatInviteCode), returned once in ServerInviteCreated. The server stores
// and compares only inviteCodeHash, sha256 of the raw bytes, so any spelling parseInviteCode
// accepts (lower case, without dashes, O for 0, I or L for 1) is the same code.
INVITE_CODE_BYTES :: 20
INVITE_CODE_SYMBOLS :: 32 // INVITE_CODE_BYTES * 8 / 5
INVITE_CODE_GROUP :: 4
// What a client may send as ClientRegister.inviteCode (with spaces and dashes).
INVITE_CODE_TEXT_MAX_BYTES :: 64
InviteCodeBytes :: [INVITE_CODE_BYTES]u8
InviteCodeHash :: [32]u8

@(private = "file")
CROCKFORD_ALPHABET :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// Limits checked by the router and again by the database where they matter.
INVITE_NOTE_MAX_BYTES :: 200
INVITE_MAX_USES :: 1000
// Longest expiry an admin may set; 0 means the code never expires.
INVITE_EXPIRY_MAX_SECONDS :: 365 * 24 * 60 * 60
// Non-admin inviters must set an expiry of at most this (D10).
INVITE_INVITER_EXPIRY_MAX_SECONDS :: 7 * 24 * 60 * 60
// Most usable codes (not revoked, not expired, uses left) a non-admin inviter may hold.
INVITES_ACTIVE_MAX_PER_INVITER :: 25
// Most codes ServerInviteList and requests ServerRegistrationRequests carry, newest first.
INVITE_LIST_MAX :: 200
REGISTRATION_REQUESTS_LIST_MAX :: 100
// An applicant's reason and an approver's decision reason, in characters (D14).
REGISTRATION_REASON_MAX_CHARS :: 500
// D13: answers per registering session, and how long it may stay registering.
REGISTER_ATTEMPTS_MAX :: 5
REGISTER_SESSION_SECONDS :: 10 * 60
// How many sessions may be registering at once; more are refused with
// REGISTRATION_BUSY_MESSAGE and may try again later.
REGISTERING_SESSIONS_MAX :: 64

// Sentences the server sends. A registering session never learns more about a code than
// INVITE_CODE_INVALID_MESSAGE, whether it is unknown, expired, used up or revoked.
INVITE_CODE_INVALID_MESSAGE :: "This invite code is not valid"
REGISTRATION_REQUIRED_MESSAGE :: "This server needs an invite code to sign up"
REGISTRATION_APPROVAL_REQUIRED_MESSAGE :: "This server needs an invite code and approval to sign up"
REGISTRATION_OPEN_MESSAGE :: "Enter your invite code to sign up"
REGISTRATION_PENDING_MESSAGE :: "Your sign-up request is waiting for approval"
REGISTRATION_DECLINED_MESSAGE :: "Your sign-up request was declined"
REGISTRATION_REASON_REQUIRED_MESSAGE :: "This invite code needs a reason for your sign-up"
REGISTRATION_NAME_TAKEN_MESSAGE :: "This name is already in use on this server"
REGISTRATION_INVALID_MESSAGE :: "Invalid sign-up request"
REGISTRATION_BUSY_MESSAGE :: "Too many sign-ups are in progress; try again later"
REGISTRATION_TIMED_OUT_MESSAGE :: "Sign-up took too long"
REGISTRATION_ATTEMPTS_MESSAGE :: "Too many sign-up attempts"
INVITE_INVALID_REQUEST_MESSAGE :: "Invalid invite request"
INVITE_NOT_PERMITTED_MESSAGE :: "You cannot create invite codes"
INVITE_ADMIN_REQUIRED_MESSAGE :: "Only admins can attach roles, a room or skip approval"
INVITE_EXPIRY_REQUIRED_MESSAGE :: "Your invite codes must expire within 7 days"
INVITE_BAD_ROOM_MESSAGE :: "An invite code can only target an unencrypted invite room"
INVITE_UNKNOWN_ROLE_MESSAGE :: "Unknown role"
INVITE_TOO_MANY_MESSAGE :: "You have too many active invite codes"
INVITE_UNKNOWN_MESSAGE :: "Unknown invite code"
REGISTRATION_APPROVER_REQUIRED_MESSAGE :: "Approve registrations permission required"
REGISTRATION_UNKNOWN_REQUEST_MESSAGE :: "Unknown sign-up request"
REGISTRATION_ALREADY_DECIDED_MESSAGE :: "This sign-up request was already decided"
// #115: an approver cannot approve a room code's request whose room is gone or no longer an
// unencrypted invite room; a request approved before that is declined by the server at the
// applicant's sign-in with REGISTRATION_ROOM_GONE_REASON as its reason.
REGISTRATION_ROOM_UNAVAILABLE_MESSAGE :: "The room this invite was for is no longer available"
REGISTRATION_ROOM_GONE_REASON ::
	"The room this invite was for is no longer available; ask for a new invite"
REGISTRATION_DECISION_INVALID_MESSAGE :: "Invalid sign-up decision"
REGISTRATION_MODE_INVALID_MESSAGE :: "Invalid registration mode"
RESTRICTED_INVALID_MESSAGE :: "Invalid restriction request"
// D17: a direct message involving a restricted account needs a shared room (or an admin).
DIRECT_MESSAGE_RESTRICTED_MESSAGE :: "You no longer share a room with this person"
// D11: only room member managers (and admins) add a restricted account to a room.
ROOM_MEMBER_RESTRICTED_MESSAGE :: "Only a member manager can add this restricted account"

// ServerRegistrationRequired (plaintext handshake response): the key has no account here.
// mode is the server's mode; status the key's request (None, Pending, or Declined with the
// approver's reason in message); otherwise message is a sentence for the sign-in screen.
// message is owned once decoded.
ServerRegistrationRequiredPayload :: struct {
	mode:    RegistrationMode,
	status:  RegistrationRequestStatus,
	message: string,
}

ServerRegistrationRequiredPayload_deinit :: proc(payload: ^ServerRegistrationRequiredPayload) {
	delete(payload.message)
	payload.message = ""
}

// ClientAdminSetRegistrationMode: admins only (ManageRegistration). Answered with
// ServerAdminActionResult{SetRegistrationMode}; a change sends ServerRegistrationMode to every
// authenticated session.
ClientAdminSetRegistrationModePayload :: struct {
	mode: RegistrationMode,
}

ServerRegistrationModePayload :: struct {
	mode: RegistrationMode,
}

// One invite code as its creator and admins see it; the code itself is never in it.
// createdBy is 0 for a code an operator made with deploy/sql/create-invite.sql. expiresAt is
// empty for a code that never expires and maxUses 0 for one without a limit. roomId is the
// room a restricted code joins (0 when that room was deleted or for a plain code). Strings and
// roleIds are owned once decoded (InviteSummary_deinit).
InviteSummary :: struct {
	id:                int,
	note:              string,
	createdBy:         int,
	createdByNickname: string,
	createdAt:         string,
	expiresAt:         string,
	maxUses:           int,
	uses:              int,
	revoked:           bool,
	roleIds:           [dynamic]int,
	roomId:            int,
	restricted:        bool,
	skipApproval:      bool,
}

InviteSummary_deinit :: proc(invite: ^InviteSummary) {
	delete(invite.note)
	delete(invite.createdByNickname)
	delete(invite.createdAt)
	delete(invite.expiresAt)
	delete(invite.roleIds)
	invite^ = {}
}

// ClientCreateInvite: holders of CreateInvites. note at most INVITE_NOTE_MAX_BYTES;
// expiresInSeconds 0 (never, admins only) or 1..INVITE_EXPIRY_MAX_SECONDS (non-admins at most
// INVITE_INVITER_EXPIRY_MAX_SECONDS); maxUses 0 (no limit) or 1..INVITE_MAX_USES. Only admins
// may set roleIds (distinct, at most SERVER_ROLES_MAX, never admin), roomId (an unencrypted
// Member or Admin invite room: accounts it creates are restricted to it, D11) or skipApproval.
// note and roleIds are owned once decoded.
ClientCreateInvitePayload :: struct {
	note:             string,
	expiresInSeconds: int,
	maxUses:          int,
	roleIds:          [dynamic]int,
	roomId:           int,
	skipApproval:     bool,
}

ClientCreateInvitePayload_deinit :: proc(payload: ^ClientCreateInvitePayload) {
	delete(payload.note)
	payload.note = ""
	delete(payload.roleIds)
	payload.roleIds = nil
}

// ServerInviteCreated: to the creating session only. code (formatInviteCode) is never sent or
// stored again. Owned once decoded.
ServerInviteCreatedPayload :: struct {
	invite: InviteSummary,
	code:   string,
}

ServerInviteCreatedPayload_deinit :: proc(payload: ^ServerInviteCreatedPayload) {
	InviteSummary_deinit(&payload.invite)
	wipeAndDeleteString(&payload.code)
}

// ClientListInvites: no fields. Admins get every code, other CreateInvites holders their own.
ClientListInvitesPayload :: struct {}

ServerInviteListPayload :: struct {
	invites: [dynamic]InviteSummary,
}

ServerInviteListPayload_deinit :: proc(payload: ^ServerInviteListPayload) {
	for &invite in payload.invites {
		InviteSummary_deinit(&invite)
	}
	delete(payload.invites)
	payload.invites = nil
}

// ClientRevokeInvite: admins revoke any code, other CreateInvites holders their own. Answered
// with ServerAdminActionResult{RevokeInvite, inviteId}. A revoked code stops working at once;
// requests already made with it stay for the approvers.
ClientRevokeInvitePayload :: struct {
	inviteId: int,
}

// One sign-up request as approvers see it. identityPublicKey is the applicant's key; nickname
// the name it asked for. decidedBy, decidedAt and decisionReason are set once decided. Strings
// are owned once decoded (RegistrationRequestSummary_deinit).
RegistrationRequestSummary :: struct {
	id:                int,
	nickname:          string,
	reason:            string,
	status:            RegistrationRequestStatus,
	identityPublicKey: IdentityPublicKeyBytes,
	inviteId:          int,
	inviteNote:        string,
	inviteCreatedBy:   int,
	createdAt:         string,
	decidedBy:         int,
	decidedAt:         string,
	decisionReason:    string,
}

RegistrationRequestSummary_deinit :: proc(request: ^RegistrationRequestSummary) {
	delete(request.nickname)
	delete(request.reason)
	delete(request.inviteNote)
	delete(request.createdAt)
	delete(request.decidedAt)
	delete(request.decisionReason)
	request^ = {}
}

RegistrationRequestSummary_clone :: proc(
	request: RegistrationRequestSummary,
	allocator := context.allocator,
) -> RegistrationRequestSummary {
	copy := request
	copy.nickname = strings.clone(request.nickname, allocator)
	copy.reason = strings.clone(request.reason, allocator)
	copy.inviteNote = strings.clone(request.inviteNote, allocator)
	copy.createdAt = strings.clone(request.createdAt, allocator)
	copy.decidedAt = strings.clone(request.decidedAt, allocator)
	copy.decisionReason = strings.clone(request.decisionReason, allocator)
	return copy
}

// ClientListRegistrationRequests: holders of ApproveRegistrations (admins included). The
// pending requests, oldest first, and with includeDecided also up to
// REGISTRATION_REQUESTS_LIST_MAX decided ones, newest first. An approver's client sends it
// after sign-in for the badge count (D18).
ClientListRegistrationRequestsPayload :: struct {
	includeDecided: bool,
}

// pendingCount is every pending request on the server, even when requests is cut at
// REGISTRATION_REQUESTS_LIST_MAX.
ServerRegistrationRequestsPayload :: struct {
	requests:     [dynamic]RegistrationRequestSummary,
	pendingCount: int,
}

ServerRegistrationRequestsPayload_deinit :: proc(payload: ^ServerRegistrationRequestsPayload) {
	for &request in payload.requests {
		RegistrationRequestSummary_deinit(&request)
	}
	delete(payload.requests)
	payload.requests = nil
}

// ClientDecideRegistration: holders of ApproveRegistrations approve or decline a pending
// request; reason (0..REGISTRATION_REASON_MAX_CHARS characters) is shown to a declined
// applicant. Answered with ServerAdminActionResult{DecideRegistration, requestId}. Approval
// does not create the account: the applicant's next sign-in does (D14), and a session of the
// applicant that is still registering is completed at once.
ClientDecideRegistrationPayload :: struct {
	id:      int,
	approve: bool,
	reason:  string,
}

ClientDecideRegistrationPayload_deinit :: proc(payload: ^ClientDecideRegistrationPayload) {
	delete(payload.reason)
	payload.reason = ""
}

// ServerRegistrationRequestUpdated: a request was made, approved or declined, to every
// authenticated session holding ApproveRegistrations. pendingCount is the server's pending
// count after it (the badge, D18). Owned once decoded.
ServerRegistrationRequestUpdatedPayload :: struct {
	request:      RegistrationRequestSummary,
	pendingCount: int,
}

ServerRegistrationRequestUpdatedPayload_deinit :: proc(
	payload: ^ServerRegistrationRequestUpdatedPayload,
) {
	RegistrationRequestSummary_deinit(&payload.request)
}

// ClientAdminSetRestricted: admins set or lift an account's restriction (D11). Lifting it adds
// the account to every Public room in the same statement; setting it removes no membership.
// Admins cannot be restricted. Answered with ServerAdminActionResult{SetRestricted}.
ClientAdminSetRestrictedPayload :: struct {
	userId:     int,
	restricted: bool,
}

// Zeroes a string's bytes before freeing it, for invite codes.
wipeAndDeleteString :: proc(value: ^string) {
	if len(value^) > 0 {
		bytes := transmute([]u8)value^
		crypto.zero_explicit(raw_data(bytes), len(bytes))
	}
	delete(value^)
	value^ = ""
}

// A new random invite code. ok is false without a system CSPRNG.
generateInviteCode :: proc() -> (code: InviteCodeBytes, ok: bool) {
	if !generateRandomBytes(code[:]) {
		return {}, false
	}
	return code, true
}

// The code as people see it: INVITE_CODE_SYMBOLS Crockford base32 symbols, most significant
// bit first, in groups of INVITE_CODE_GROUP joined by dashes. Allocated with allocator.
formatInviteCode :: proc(code: InviteCodeBytes, allocator := context.allocator) -> string {
	alphabet := CROCKFORD_ALPHABET
	builder := strings.builder_make(allocator)
	for symbol in 0 ..< INVITE_CODE_SYMBOLS {
		if symbol > 0 && symbol % INVITE_CODE_GROUP == 0 {
			strings.write_byte(&builder, '-')
		}
		value := 0
		for bit in 0 ..< 5 {
			index := symbol * 5 + bit
			value = value << 1 | int((code[index / 8] >> uint(7 - index % 8)) & 1)
		}
		strings.write_byte(&builder, alphabet[value])
	}
	return strings.to_string(builder)
}

@(private = "file")
crockfordValue :: proc(r: rune) -> (int, bool) {
	switch r {
	case '0' ..= '9':
		return int(r - '0'), true
	case 'o', 'O':
		return 0, true
	case 'i', 'I', 'l', 'L':
		return 1, true
	}
	upper := r
	if r >= 'a' && r <= 'z' {
		upper = r - 'a' + 'A'
	}
	for candidate, index in CROCKFORD_ALPHABET {
		if candidate == upper {
			return index, true
		}
	}
	return 0, false
}

// Reads a code as a person may type or paste it: Crockford base32 in either case, with O read
// as 0 and I or L as 1, ignoring spaces, tabs and dashes. Anything else, a text longer than
// INVITE_CODE_TEXT_MAX_BYTES, or a symbol count other than INVITE_CODE_SYMBOLS is refused.
parseInviteCode :: proc(text: string) -> (code: InviteCodeBytes, ok: bool) {
	if len(text) > INVITE_CODE_TEXT_MAX_BYTES || !utf8.valid_string(text) {
		return {}, false
	}
	symbols := 0
	for r in text {
		if r == '-' || r == ' ' || r == '\t' {
			continue
		}
		value, valueOK := crockfordValue(r)
		if !valueOK || symbols >= INVITE_CODE_SYMBOLS {
			return {}, false
		}
		for bit in 0 ..< 5 {
			index := symbols * 5 + bit
			if (value >> uint(4 - bit)) & 1 == 1 {
				code[index / 8] |= 1 << uint(7 - index % 8)
			}
		}
		symbols += 1
	}
	if symbols != INVITE_CODE_SYMBOLS {
		return {}, false
	}
	return code, true
}

// sha256 of the code's raw bytes, what invites.code_hash stores.
inviteCodeHash :: proc(code: InviteCodeBytes) -> InviteCodeHash {
	hash: InviteCodeHash
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	bytes := code
	sha2.update(&ctx, bytes[:])
	sha2.final(&ctx, hash[:])
	crypto.zero_explicit(&bytes, size_of(bytes))
	return hash
}

// Whether text has 1..maxChars characters (maxChars counts runes, like VARCHAR(n)), is valid
// UTF-8 and has no control character other than a newline.
registrationTextIsValid :: proc(text: string, minChars: int, maxChars: int) -> bool {
	if !utf8.valid_string(text) {
		return false
	}
	count := utf8.rune_count_in_string(text)
	if count < minChars || count > maxChars {
		return false
	}
	for r in text {
		if (r < 0x20 && r != '\n') || r == 0x7f {
			return false
		}
	}
	return true
}

// Whether a ClientCreateInvite has a valid shape (the database checks the permissions, the
// roles and the room).
inviteCreateRequestIsValid :: proc(request: ClientCreateInvitePayload) -> bool {
	if len(request.note) > INVITE_NOTE_MAX_BYTES ||
	   !registrationTextIsValid(request.note, 0, INVITE_NOTE_MAX_BYTES) {
		return false
	}
	if request.expiresInSeconds < 0 || request.expiresInSeconds > INVITE_EXPIRY_MAX_SECONDS {
		return false
	}
	if request.maxUses < 0 || request.maxUses > INVITE_MAX_USES {
		return false
	}
	if request.roomId < 0 || len(request.roleIds) > SERVER_ROLES_MAX {
		return false
	}
	for roleID, index in request.roleIds {
		if roleID <= 0 {
			return false
		}
		for earlier in request.roleIds[:index] {
			if earlier == roleID {
				return false
			}
		}
	}
	return true
}

// Database IPC for registration (server/database_registration.odin). Every statement checks
// its permission and guards in the same statement as the change (D4).

// One ClientRegister. codeHash is inviteCodeHash of the parsed code, hasCode false for an
// empty code (only an Open server accepts that). nickname (owned) is the session's ClientHello
// name and reason (owned) the applicant's.
DatabaseRegisterRequest :: struct {
	publicKey: IdentityPublicKeyBytes,
	nickname:  string,
	codeHash:  InviteCodeHash,
	hasCode:   bool,
	reason:    string,
}

// How a register statement ended.
DatabaseRegisterOutcome :: enum u8 {
	Created, // The account exists (identity fields set)
	Pending, // A request waits for approval (request and pendingCount set)
	AlreadyPending, // The key already has a pending or approved request; nothing changed
	InvalidCode, // Unknown, revoked, expired, used up, or its room is gone; or no code
	NameTaken, // Another account holds the name
	ReasonRequired, // The code needs approval and the reason is empty
	HasAccount, // The key already owns an account (it should have signed in)
}

// Created fills the identity fields (nickname and roleIds owned; roleIds the code's roles,
// #102), Pending request (owned) and pendingCount; the code's ID is inviteId for both.
DatabaseRegisterResult :: struct {
	outcome:          DatabaseRegisterOutcome,
	userId:           int,
	nickname:         string,
	permissions:      ServerPermissions,
	isRestricted:     bool,
	roleIds:          [dynamic]int,
	registrationMode: RegistrationMode,
	inviteId:         int,
	request:          RegistrationRequestSummary,
	pendingCount:     int,
}

DatabaseInviteAction :: enum u8 {
	Create,
	List,
	Revoke,
}

// Create uses codeHash, note (owned), expiresInSeconds, maxUses, roleIds (owned), roomId and
// skipApproval; Revoke inviteId; List nothing else.
DatabaseInviteRequest :: struct {
	action:           DatabaseInviteAction,
	actorUserId:      int,
	codeHash:         InviteCodeHash,
	note:             string,
	expiresInSeconds: int,
	maxUses:          int,
	roleIds:          [dynamic]int,
	roomId:           int,
	skipApproval:     bool,
	inviteId:         int,
}

DatabaseInviteOutcome :: enum u8 {
	Applied,
	NotPermitted, // No CreateInvites (or, for List and Revoke, neither that nor admin)
	AdminRequired, // Roles, a room, skip approval or no expiry from a non-admin (D10)
	ExpiryTooLong, // A non-admin's expiry beyond INVITE_INVITER_EXPIRY_MAX_SECONDS
	UnknownRole, // A role that does not exist or is the built-in one
	BadRoom, // The room is missing, Public, a Role room or encrypted
	TooManyInvites, // A non-admin already holds INVITES_ACTIVE_MAX_PER_INVITER usable codes
	UnknownInvite, // No such code, or (non-admins) not one of theirs
}

// Applied: Create fills invite, List invites, Revoke invite and changed. Everything is owned.
DatabaseInviteResult :: struct {
	outcome: DatabaseInviteOutcome,
	changed: bool,
	invite:  InviteSummary,
	invites: [dynamic]InviteSummary,
}

DatabaseRegistrationRequestsAction :: enum u8 {
	List,
	Decide,
}

// List uses includeDecided; Decide requestId, approve and reason (owned).
DatabaseRegistrationRequestsRequest :: struct {
	action:         DatabaseRegistrationRequestsAction,
	actorUserId:    int,
	includeDecided: bool,
	requestId:      int,
	approve:        bool,
	reason:         string,
}

DatabaseRegistrationRequestsOutcome :: enum u8 {
	Applied,
	NotPermitted, // No ApproveRegistrations
	UnknownRequest,
	AlreadyDecided,
	RoomUnavailable, // #115: approving a room code's request whose room is no longer usable
}

// Applied: List fills requests (owned), Decide request (owned); both pendingCount.
DatabaseRegistrationRequestsResult :: struct {
	outcome:      DatabaseRegistrationRequestsOutcome,
	requests:     [dynamic]RegistrationRequestSummary,
	request:      RegistrationRequestSummary,
	pendingCount: int,
}

// Sets the mode when actorUserId is an admin.
DatabaseRegistrationModeRequest :: struct {
	actorUserId: int,
	mode:        RegistrationMode,
}

DatabaseRegistrationModeResult :: struct {
	allowed: bool,
	changed: bool,
	mode:    RegistrationMode,
}

// Which of candidateUserIds (owned) share a room with userId (D17 presence filtering).
DatabaseSharedRoomsRequest :: struct {
	userId:           int,
	candidateUserIds: [dynamic]int,
}

DatabaseSharedRoomsResult :: struct {
	userIds: [dynamic]int,
}

// Every restricted account, loaded once when the router starts.
DatabaseRestrictedUsersRequest :: struct {}

DatabaseRestrictedUsersResult :: struct {
	userIds: [dynamic]int,
}

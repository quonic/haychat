package common

import "core:encoding/cbor"
import "core:fmt"
import "core:strings"
import "core:testing"

// Protocol 28 (attachments F3): the moderation payloads round-trip through CBOR.
@(test)
testAttachmentModerationPayloadsRoundTrip :: proc(t: ^testing.T) {
	_ = t
	blobId: AttachmentBlobID
	for index in 0 ..< len(blobId) {
		blobId[index] = u8(index + 1)
	}

	remove := ClientAdminRemoveAttachmentPayload {
		blobId = blobId,
		reason = "spam",
	}
	encoded, err := cbor.marshal(remove)
	assert(err == nil, "expected the removal to encode")
	decodedRemove: ClientAdminRemoveAttachmentPayload
	assert(
		cbor.unmarshal(encoded, &decodedRemove, temp_allocator = context.allocator) == nil,
		"expected the removal to decode",
	)
	delete(encoded)
	defer ClientAdminRemoveAttachmentPayload_deinit(&decodedRemove)
	assert(
		decodedRemove.blobId == blobId && decodedRemove.reason == "spam",
		fmt.tprintf("expected the removal to round-trip, got %v", decodedRemove),
	)

	removed := ServerAttachmentRemovedPayload {
		blobId      = blobId,
		roomId      = 0,
		senderId    = 4,
		recipientId = 9,
	}
	encoded, err = cbor.marshal(removed)
	assert(err == nil, "expected the removed notice to encode")
	decodedRemoved: ServerAttachmentRemovedPayload
	assert(
		cbor.unmarshal(encoded, &decodedRemoved, temp_allocator = context.allocator) == nil,
		"expected the removed notice to decode",
	)
	delete(encoded)
	assert(
		decodedRemoved == removed,
		fmt.tprintf("expected the removed notice to round-trip, got %v", decodedRemoved),
	)

	usage := ServerAdminAttachmentUsagePayload {
		usedBytes      = 3000,
		capacityBytes  = 1 << 30,
		freeBytes      = 5 << 30,
		freeBytesKnown = true,
	}
	usage.accounts = make([dynamic]AttachmentAccountUsage, 0, 2)
	defer delete(usage.accounts)
	append(&usage.accounts, AttachmentAccountUsage{userId = 2, bytes = 2000, count = 3})
	append(&usage.accounts, AttachmentAccountUsage{userId = 5, bytes = 1000, count = 1})
	encoded, err = cbor.marshal(usage)
	assert(err == nil, "expected the usage to encode")
	decodedUsage: ServerAdminAttachmentUsagePayload
	assert(cbor.unmarshal(encoded, &decodedUsage) == nil, "expected the usage to decode")
	delete(encoded)
	defer ServerAdminAttachmentUsagePayload_deinit(&decodedUsage)
	assert(
		decodedUsage.usedBytes == 3000 &&
		decodedUsage.capacityBytes == 1 << 30 &&
		decodedUsage.freeBytes == 5 << 30 &&
		decodedUsage.freeBytesKnown &&
		len(decodedUsage.accounts) == 2 &&
		decodedUsage.accounts[0] == usage.accounts[0] &&
		decodedUsage.accounts[1] == usage.accounts[1],
		fmt.tprintf("expected the usage to round-trip, got %v", decodedUsage),
	)

	result := ServerAdminActionResultPayload {
		action  = .RemoveAttachment,
		userId  = 4,
		message = "Removed the attachment",
		blobId  = blobId,
	}
	encoded, err = cbor.marshal(result)
	assert(err == nil, "expected the admin result to encode")
	decodedResult: ServerAdminActionResultPayload
	assert(
		cbor.unmarshal(encoded, &decodedResult, temp_allocator = context.allocator) == nil,
		"expected the admin result to decode",
	)
	delete(encoded)
	defer ServerAdminActionResultPayload_deinit(&decodedResult)
	assert(
		decodedResult.action == .RemoveAttachment &&
		decodedResult.userId == 4 &&
		decodedResult.blobId == blobId,
		fmt.tprintf("expected the admin result to carry the blob, got %v", decodedResult),
	)
}

@(test)
testAttachmentRemoveReasonValidation :: proc(t: ^testing.T) {
	_ = t
	assert(attachmentRemoveReasonIsValid(""), "expected an empty reason to be allowed")
	assert(attachmentRemoveReasonIsValid("Spam: see ticket 4"), "expected a plain reason")
	assert(attachmentRemoveReasonIsValid("naïve 🙂"), "expected UTF-8 to be allowed")
	longest := strings.repeat("r", ATTACHMENT_REMOVE_REASON_MAX_BYTES, context.temp_allocator)
	assert(attachmentRemoveReasonIsValid(longest), "expected 500 bytes to be allowed")
	tooLong := strings.repeat("r", ATTACHMENT_REMOVE_REASON_MAX_BYTES + 1, context.temp_allocator)
	assert(!attachmentRemoveReasonIsValid(tooLong), "expected 501 bytes to be refused")
	assert(!attachmentRemoveReasonIsValid("line\nbreak"), "expected a newline to be refused")
	assert(!attachmentRemoveReasonIsValid("tab\there"), "expected a tab to be refused")
	assert(!attachmentRemoveReasonIsValid("del\x7f"), "expected DEL to be refused")
	assert(!attachmentRemoveReasonIsValid("c1\u0085"), "expected a C1 control to be refused")
	assert(!attachmentRemoveReasonIsValid("\xff"), "expected invalid UTF-8 to be refused")
}

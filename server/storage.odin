package server

import "core:fmt"
import "core:hash"
import "core:os"
import "core:time"
import "core:time/datetime"

// This is for the management of file storage that users can upload, such as profile pictures and chat attachments. It will handle saving files to disk, generating unique filenames, and cleaning up old files.

File :: struct {
	filename:   string, // The original filename uploaded by the user
	hashedName: string, // A unique hashed filename used for storage to avoid collisions
	uploadTime: datetime.DateTime, // Timestamp of when the file was uploaded, used for cleanup
	size:       i64, // Size of the file in bytes
	userId:     int, // ID of the user who uploaded the file, for ownership and permissions
}

saveFile :: proc(
	config: ^ServerConfig,
	fileData: []u8,
	originalFilename: string,
	userId: int,
) -> (
	hashedFilename: string,
	success: bool,
) {
	// Generate a unique hashed filename using a combination of the original filename, user ID, and current timestamp
	hashedName := generateHashedFilename(originalFilename, userId)

	// Save the file to disk in the configured storage directory
	filePath := fmt.aprintf("%s/%s", config.fileStoragePath, hashedName)
	err := os.write_entire_file_from_bytes(filePath, fileData)
	if err != nil {
		return "", false
	}

	// Create a new File struct to track this uploaded file
	currentDateTime, _ := time.time_to_datetime(time.now())
	newFile := File {
		filename   = originalFilename,
		hashedName = hashedName,
		uploadTime = currentDateTime,
		size       = i64(len(fileData)),
		userId     = userId,
	}

	// Add the new file to the storage tracking system (e.g., a database or in-memory map)
	// This part is left as a placeholder for integration with your storage management system
	// addFileToStorage(newFile)

	return hashedName, true
}

getFileFromHash :: proc(
	config: ^ServerConfig,
	hashedFilename: string,
) -> (
	fileData: []u8,
	success: bool,
) {
	// Construct the file path from the hashed filename
	filePath := fmt.aprintf("%s/%s", config.fileStoragePath, hashedFilename)

	// Read the file data from disk
	data, err := os.read_entire_file_from_path(filePath, context.allocator)
	if err != nil {
		return nil, false
	}

	return data, true
}

// Utility function to generate a unique hashed filename based on the original filename, user ID, and current timestamp
// This is just to hash a filename to ensure that there are no collisions in the storage directory. The original filename is not used for storage, but can be kept in a database for reference if needed.
generateHashedFilename :: proc(originalFilename: string, userId: int) -> string {
	timestamp := time.now()
	uniqueString := fmt.aprintf("%s_%d_%d", originalFilename, userId, timestamp)

	hashedValue := hash.murmur64a(transmute([]u8)uniqueString)
	hashedFilename := fmt.aprintf("%x", hashedValue)

	return hashedFilename
}

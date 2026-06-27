package server

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"

// This is for the management of file storage that users can upload, such as profile pictures and chat attachments. It will handle saving files to disk, generating unique filenames, and cleaning up old files.

STORAGE_MANIFEST_FILENAME :: "manifest.json"

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
	message: string,
	success: bool,
) {
	if len(strings.trim_space(originalFilename)) == 0 {
		return "", "filename is required", false
	}
	if len(fileData) == 0 {
		return "", "file content is required", false
	}

	fileSize := i64(len(fileData))
	if fileSize > config.maxFileSize {
		return "", "file exceeds max size", false
	}
	if !ensureDirectoryPathExists(config.fileStoragePath) {
		return "", "file storage path is unavailable", false
	}

	manifest, manifestOK := loadStorageManifest(config)
	if !manifestOK {
		return "", "failed to load storage manifest", false
	}

	hashedName := generateHashedFilename(originalFilename, fileData)
	if _, exists := findManifestEntry(manifest, hashedName); exists {
		return hashedName, "ok", true
	}

	usedCapacity := storageManifestUsedCapacity(manifest)
	if usedCapacity + fileSize > config.maxStorageCapacity {
		return "", "storage capacity exceeded", false
	}

	filePath := storageFilePath(config, hashedName)
	err := os.write_entire_file_from_bytes(filePath, fileData)
	if err != nil {
		return "", "failed to write file", false
	}

	currentDateTime, _ := time.time_to_datetime(time.now())
	newFile := File {
		filename   = sanitizeStoredFilename(originalFilename),
		hashedName = hashedName,
		uploadTime = currentDateTime,
		size       = fileSize,
		userId     = userId,
	}
	append(&manifest, newFile)

	if !saveStorageManifest(config, manifest) {
		return "", "failed to update storage manifest", false
	}

	return hashedName, "ok", true
}

getFileFromHash :: proc(
	config: ^ServerConfig,
	hashedFilename: string,
) -> (
	fileData: []u8,
	success: bool,
) {
	manifest, manifestOK := loadStorageManifest(config)
	if !manifestOK {
		return nil, false
	}
	if _, exists := findManifestEntry(manifest, hashedFilename); !exists {
		return nil, false
	}

	data, err := os.read_entire_file_from_path(
		storageFilePath(config, hashedFilename),
		context.allocator,
	)
	if err != nil {
		return nil, false
	}

	return data, true
}

storageManifestPath :: proc(config: ^ServerConfig) -> string {
	return fmt.aprintf("%s/%s", config.fileStoragePath, STORAGE_MANIFEST_FILENAME)
}

storageFilePath :: proc(config: ^ServerConfig, hashedFilename: string) -> string {
	return fmt.aprintf("%s/%s", config.fileStoragePath, hashedFilename)
}

loadStorageManifest :: proc(config: ^ServerConfig) -> ([dynamic]File, bool) {
	manifestPath := storageManifestPath(config)
	if !os.exists(manifestPath) {
		return make([dynamic]File), true
	}

	data, err := os.read_entire_file_from_path(manifestPath, context.allocator)
	if err != nil {
		return nil, false
	}
	if len(data) == 0 {
		return make([dynamic]File), true
	}

	manifest: [dynamic]File
	json.unmarshal(data, &manifest)
	return manifest, true
}

saveStorageManifest :: proc(config: ^ServerConfig, manifest: [dynamic]File) -> bool {
	manifestPath := storageManifestPath(config)
	jsonData, err := json.marshal(manifest)
	if err != nil {
		return false
	}
	writeErr := os.write_entire_file_from_bytes(manifestPath, jsonData)
	if writeErr != nil {
		return false
	}
	return true
}

findManifestEntry :: proc(manifest: [dynamic]File, hashedFilename: string) -> (File, bool) {
	for entry in manifest {
		if entry.hashedName == hashedFilename {
			return entry, true
		}
	}
	return {}, false
}

storageManifestUsedCapacity :: proc(manifest: [dynamic]File) -> i64 {
	usedCapacity: i64 = 0
	for entry in manifest {
		usedCapacity += entry.size
	}
	return usedCapacity
}

sanitizeStoredFilename :: proc(originalFilename: string) -> string {
	sanitized := strings.trim_space(originalFilename)
	if len(sanitized) == 0 {
		return "upload.bin"
	}

	result := make([dynamic]u8, 0, len(sanitized))
	for i in 0 ..< len(sanitized) {
		ch := sanitized[i]
		switch ch {
		case '/', '\\', 0:
			append(&result, u8('_'))
		case:
			append(&result, ch)
		}
	}
	return string(result[:])
}

getSafeFilenameExtension :: proc(originalFilename: string) -> string {
	lastDot := -1
	for i := len(originalFilename) - 1; i >= 0; i -= 1 {
		if originalFilename[i] == '.' {
			lastDot = i
			break
		}
		if originalFilename[i] == '/' || originalFilename[i] == '\\' {
			break
		}
	}
	if lastDot < 0 || lastDot == len(originalFilename) - 1 {
		return ""
	}

	extension := originalFilename[lastDot:]
	result := make([dynamic]u8, 0, len(extension))
	for i in 0 ..< len(extension) {
		ch := extension[i]
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') ||
		   ch == '.' ||
		   ch == '_' ||
		   ch == '-' {
			append(&result, ch)
		}
	}
	return string(result[:])
}

// Utility function to generate a deterministic hashed filename based on content and safe extension.
generateHashedFilename :: proc(originalFilename: string, fileData: []u8) -> string {
	hashedValue := hash.murmur64a(fileData)
	hashedFilename := fmt.aprintf("%x", hashedValue)
	extension := getSafeFilenameExtension(originalFilename)
	if len(extension) > 0 {
		return fmt.aprintf("%s%s", hashedFilename, extension)
	}
	return hashedFilename
}

package server

import "../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

configTestStorageConfig :: proc(storagePath: string) -> ServerConfig {
	config := ServerConfig {
		fileStoragePath = storagePath,
	}
	routerTestGenerateValidIdentityConfig(&config)
	config.webAdminTokenFilePath = fmt.aprintf("%s/%s", storagePath, DEFAULT_WEB_ADMIN_TOKEN_FILE_NAME)
	return config
}

@(test)
testConfigStartupPreflightRejectsInvalidAdminPublicKey :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_admin_key")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.adminPublicKey = "not-a-key"
	preflightErr := startupPreflightError(config)
	assert(
		strings.contains(preflightErr, "HAYCHAT_ADMIN_PUBLIC_KEY"),
		fmt.tprintf("expected invalid admin key to fail preflight, got %q", preflightErr),
	)

	_, adminPublicKey, keyOK := common.generateIdentityKeyPair()
	assert(keyOK, "expected admin key generation to succeed")
	config.adminPublicKey = common.identityPublicKeyToHex(adminPublicKey)
	preflightErr = startupPreflightError(config)
	assert(
		len(preflightErr) == 0,
		fmt.tprintf("expected valid admin key to pass preflight, got %q", preflightErr),
	)
}

@(test)
testConfigStartupPreflightRejectsShortWebAdminToken :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_short_token")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.webAdminToken = "too-short"
	preflightErr := startupPreflightError(config)
	assert(
		strings.contains(preflightErr, "HAYCHAT_WEB_ADMIN_TOKEN"),
		fmt.tprintf("expected short web admin token to fail preflight, got %q", preflightErr),
	)
}

@(test)
testEnsureWebAdminTokenGeneratesPrivateFileAndReusesIt :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_token_file")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	tokenErr := ensureWebAdminToken(&config)
	assert(len(tokenErr) == 0, fmt.tprintf("expected token generation to succeed, got %q", tokenErr))
	assert(
		len(config.webAdminToken) >= WEB_ADMIN_TOKEN_MIN_LENGTH,
		fmt.tprintf("expected generated token length >= %d", WEB_ADMIN_TOKEN_MIN_LENGTH),
	)

	info, statErr := os.stat(config.webAdminTokenFilePath, context.temp_allocator)
	assert(statErr == nil, "expected generated token file to exist")
	assert(
		info.mode & os.Permissions_Read_Write_All == os.perm(0o600),
		fmt.tprintf("expected token file mode 0600, got %v", info.mode),
	)

	reloaded := configTestStorageConfig(storagePath)
	reloadErr := ensureWebAdminToken(&reloaded)
	assert(len(reloadErr) == 0, "expected persisted token reload to succeed")
	assert(
		reloaded.webAdminToken == config.webAdminToken,
		"expected restart to reuse the persisted web admin token",
	)
}

@(test)
testEnsureWebAdminTokenPrefersEnvironmentValue :: proc(t: ^testing.T) {
	// ServerConfig is process-lifetime and never freed, so config tests run on the temp allocator.
	context.allocator = context.temp_allocator
	_ = t
	storagePath := routerTestCreateTempDir("haychat_config_token_env")
	defer os.remove_all(storagePath)

	config := configTestStorageConfig(storagePath)
	config.webAdminToken = "0123456789abcdef0123456789abcdef"
	tokenErr := ensureWebAdminToken(&config)
	assert(len(tokenErr) == 0, "expected configured token to be accepted")
	assert(
		!os.exists(config.webAdminTokenFilePath),
		"expected configured token not to be written to disk",
	)
}

@(test)
testWebAdminAuthorizationRequiresExactBearerToken :: proc(t: ^testing.T) {
	_ = t
	token := "0123456789abcdef0123456789abcdef"
	assert(
		webAdminAuthorizationValid("Bearer 0123456789abcdef0123456789abcdef", token),
		"expected matching bearer token to be accepted",
	)
	assert(!webAdminAuthorizationValid("", token), "expected missing header to be rejected")
	assert(
		!webAdminAuthorizationValid("0123456789abcdef0123456789abcdef", token),
		"expected token without Bearer prefix to be rejected",
	)
	assert(
		!webAdminAuthorizationValid("Bearer 0123456789abcdef0123456789abcdee", token),
		"expected wrong token to be rejected",
	)
	assert(
		!webAdminAuthorizationValid("Bearer 0123456789abcdef", token),
		"expected token prefix to be rejected",
	)
	assert(!webAdminAuthorizationValid("Bearer ", ""), "expected empty expected token to deny")
}

@(test)
testDatabaseErrorResponsesOwnTheirStrings :: proc(t: ^testing.T) {
	_ = t
	// The router frees every response string, so literals here would crash the server.
	response := databaseExecuteRequest(nil, common.DatabaseQueryRequest{queryType = .None})
	assert(!response.success, "expected missing query type to fail")
	assert(
		response.message == "missing database query type",
		fmt.tprintf("expected missing query type message, got %q", response.message),
	)
	IPC__database_query_response_deinit(response)
}

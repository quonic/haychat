package server

import "core:crypto/mlkem"
import "core:fmt"

DefaultKeySize :: mlkem.Parameters.ML_KEM_768

/*
Cryptographic Key Management for HayChat - Server-Side

This module provides secure key exchange and encryption using:
- ML-KEM (Post-Quantum Key Encapsulation Mechanism) for key exchange and encryption/decryption.

/*
| Purpose                         | Function                       |
| ------------------------------- | ------------------------------ |
| Generate private key            | `decapsulation_key_generate`   |
| Get public key from private key | `encapsulation_key_set_decaps` |
| Serialize public key            | `encapsulation_key_bytes`      |
| Load public key from bytes      | `encapsulation_key_set_bytes`  |
| Encapsulate                     | `encaps` / `encaps_ek`         |
| Decapsulate                     | `decaps`                       |
| Export private key seed         | `decapsulation_key_bytes`      |
| Restore private key seed        | `decapsulation_key_set_bytes`  |
*/

*/

Server_Key: mlkem.Decapsulation_Key

generate_server_key :: proc() {
	// Generate a new key pair for the server
	if !mlkem.decapsulation_key_generate(&Server_Key, DefaultKeySize) {
		panic("Failed to generate server encapsulation key")
	}
}

generate_shared_secret :: proc(
	client_public_key: mlkem.Encapsulation_Key,
) -> (
	shared_secret, ciphertext: []u8,
) {
	// Extract the public key
	ek: mlkem.Encapsulation_Key
	mlkem.encapsulation_key_set_decaps(&ek, &Server_Key)

	shared_secret = make([]u8, mlkem.SHARED_SECRET_SIZE)
	ciphertext = make([]u8, mlkem.CIPHERTEXT_SIZES[.ML_KEM_768])


	if !mlkem.encaps(&ek, shared_secret, ciphertext) {
		fmt.println("Encapsulation failed")
		return nil, nil
	}
	return shared_secret, ciphertext
}

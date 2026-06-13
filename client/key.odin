package client

import "core:crypto/mlkem"
import "core:fmt"

DefaultKeySize :: mlkem.Parameters.ML_KEM_768

/*
Cryptographic Key Management for HayChat - Client-Side

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

Client_Key: mlkem.Decapsulation_Key

generate_client_key :: proc() {
	// Generate a new key pair for the client
	if !mlkem.decapsulation_key_generate(&Client_Key, DefaultKeySize) {
		panic("Failed to generate client encapsulation key")
	}
}

get_shared_secret :: proc(client_public_key: mlkem.Encapsulation_Key, ciphertext: []u8) -> []u8 {
	shared_secret := make([]u8, mlkem.SHARED_SECRET_SIZE)

	if !mlkem.decaps(&Client_Key, ciphertext, shared_secret) {
		fmt.println("Decapsulation failed")
		return nil
	}
	return shared_secret
}

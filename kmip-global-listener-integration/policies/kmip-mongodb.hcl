# Plain transit ACL for the MongoDB KMIP client. See internal/kmip/doc.go for
# the full KMIP operation -> path/capability table.
path "transit-mongodb/keys/*" {
  # update: Create, Register(import) · read: Get, GetAttributes, Activate, Locate by name
  # delete: Revoke (soft-delete) and Destroy
  capabilities = ["read", "update", "delete"]
}
path "transit-mongodb/keys" {
  capabilities = ["list"] # Locate by attributes only
}
path "transit-mongodb/export/encryption-key/*" {
  capabilities = ["read"] # Get returns symmetric key material
}
path "transit-mongodb/wrapping_key" {
  capabilities = ["read"] # Register wraps plaintext material before import
}
path "transit-mongodb/encrypt/*" {
  capabilities = ["update"] # not create: that would let Encrypt create keys
}
path "transit-mongodb/decrypt/*" {
  capabilities = ["update"]
}

# Plain transit ACL for the MySQL KMIP client. See internal/kmip/doc.go for
# the full KMIP operation -> path/capability table.
path "transit-mysql/keys/*" {
  # update: Create, Register(import) · read: Get, GetAttributes, Activate, Locate by name
  # delete: Revoke (soft-delete) and Destroy
  capabilities = ["read", "update", "delete"]
}
path "transit-mysql/keys" {
  capabilities = ["list"] # Locate by attributes only
}
path "transit-mysql/export/encryption-key/*" {
  capabilities = ["read"] # Get returns symmetric key material
}
path "transit-mysql/wrapping_key" {
  capabilities = ["read"] # Register wraps plaintext material before import
}
path "transit-mysql/encrypt/*" {
  capabilities = ["update"] # not create: that would let Encrypt create keys
}
path "transit-mysql/decrypt/*" {
  capabilities = ["update"]
}

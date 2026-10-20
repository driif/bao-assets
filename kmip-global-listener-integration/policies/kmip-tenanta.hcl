# Lives in the root namespace; paths carry the child namespace "tenant-a/".
path "tenant-a/transit/keys/*" {
  capabilities = ["read", "update", "delete"]
}
path "tenant-a/transit/keys" {
  capabilities = ["list"]
}
path "tenant-a/transit/export/encryption-key/*" {
  capabilities = ["read"]
}
path "tenant-a/transit/wrapping_key" {
  capabilities = ["read"]
}
path "tenant-a/transit/encrypt/*" {
  capabilities = ["update"]
}
path "tenant-a/transit/decrypt/*" {
  capabilities = ["update"]
}

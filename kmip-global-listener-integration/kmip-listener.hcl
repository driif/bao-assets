# Merged into the dev server config: bao server -dev ... -config=kmip-listener.hcl
# Paths are relative to the directory bao is started from.
listener "kmip" {
  address            = "0.0.0.0:5696"
  tls_cert_file      = "certs/server.crt"
  tls_key_file       = "certs/server.key"
  tls_client_ca_file = "certs/ca.crt"

  # Every KMIP client logs in here; cert auth picks the role from the client cert.
  auth_mount = "auth/cert"
  # Used only by roles that set no kmip_transit_mount.
  default_transit_mount = "transit"
}

# Audit devices are config-only in this OpenBao build. Each KMIP operation is
# logged as the transit (and cert auth login) requests it became.
audit "file" "kmip-audit" {
  options {
    file_path = "audit.log"
  }
}

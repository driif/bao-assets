# KMIP global listener

One `listener "kmip"` in the server config serves every KMIP client.

- A client logs in with its TLS certificate through ordinary **cert auth**.
- Each KMIP operation then runs as normal **transit** requests under that token.
- Access is therefore controlled by plain ACL policies, and every operation is audited.

```
KMIP client ──mTLS──▶ listener "kmip" :5696
                         │ 1. login: auth/cert/login (cert auth picks the role from the cert)
                         │ 2. role → token policies, kmip_transit_mount, kmip_key_prefix
                         ▼
                      transit requests as that token: ACL, audit, namespaces, HA forwarding
```

## Quick start

Needs Go, plus Docker if you want to test with the databases.

```sh
./build-bao.sh        # build ./bao from ~/Documents/work/bao/openbao (override: OPENBAO_SRC=...)
./gen-certs.sh        # test CA, server cert, clients: mongodb, mysql, rogue
./start-bao.sh        # dev server :8200 (token "root") + KMIP :5696 + audit.log; leave running
./setup-kmip.sh       # second shell: transit mounts, policies, cert roles
```

**Without Docker,** use the smoke client:

```sh
cd smoke
go run . -as mysql                          # every op ok; Destroy fails: deletion_allowed=false
go run . -as mongodb -get mysql-smoke-key   # ItemNotFound: mongodb's role uses another mount
go run . -as rogue                          # PermissionDenied: no cert role matches
```

**With Percona MongoDB and MySQL:**

```sh
docker compose up -d
export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root
./bao list transit-mongodb/keys     # mongodb-<uuid>, created at startup
docker exec percona-mysql mysql -uroot -prootpass testdb -e "
  CREATE TABLE IF NOT EXISTS secrets (id INT PRIMARY KEY AUTO_INCREMENT, msg VARCHAR(64)) ENCRYPTION='Y';
  INSERT INTO secrets (msg) VALUES ('hello'); SELECT * FROM secrets;"
./bao list transit-mysql/keys       # INNODBKey-<uuid>-1, created on the first encrypted table
docker compose down -v              # reset
```

Each operation shows up in `audit.log` as `auth/cert/login` plus transit
requests, for example `update transit-mysql/keys/<name>`.

If your default `go` is newer than OpenBao's, prefix the `go run` commands with
`GOTOOLCHAIN=go$(cat ~/Documents/work/bao/openbao/.go-version)`.

## How it differs from `../kmip-integration` (step 1)

| | Step 1 | Step 2 (here) |
|---|---|---|
| Server | Per transit mount, `transit/config/kmip` | One `listener "kmip"` in server config |
| TLS files | PEM strings stored in the mount | Files on disk, reloaded on SIGHUP |
| Client identity | `transit/kmip/roles`, exact subject DN | `auth/cert/certs/*`: CN, SANs, OU... |
| Permissions | Allowed KMIP operations, for all keys in the mount | ACL policies on transit paths, per key or glob |
| Audit | None | Every operation |
| Key mount | The mount that runs the listener | Per role: `kmip_transit_mount` |
| Keys created without a Name | UUID | `kmip_key_prefix` + UUID |
| Revoke | No-op | Soft-delete; the key reads back as `Deactivated` |
| Destroy | Deletes the key | Fails unless the key has `deletion_allowed=true` |
| HA | Only the node running the listener | Every node; standbys forward writes |

The database side (`docker-compose.yml`, `configs/`) is unchanged.

## Configuration reference

**Listener** (`kmip-listener.hcl`):

```hcl
listener "kmip" {
  address               = "0.0.0.0:5696"
  tls_cert_file         = "certs/server.crt"
  tls_key_file          = "certs/server.key"
  tls_client_ca_file    = "certs/ca.crt"   # client certs must chain to this
  auth_mount            = "auth/cert"      # where clients log in; its namespace is the base
  default_transit_mount = "transit"        # for roles without kmip_transit_mount
}
```

**Cert role.** It decides who the client is and where its keys go:

```sh
bao write auth/cert/certs/mysql \
  certificate=@certs/ca.crt \
  allowed_common_names=mysql-kmip \
  token_policies=kmip-mysql \
  token_type=batch token_ttl=1h \
  kmip_transit_mount=transit-mysql \
  kmip_key_prefix=mysql-
```

- `certificate` and `allowed_*` select the role. The client sends no role name,
  so keep the role constraints from overlapping.
- `token_policies` decide what the client may do.
- `kmip_transit_mount` is relative to the auth mount's namespace and may include a
  child namespace, for example `tenant-a/transit`.
- `kmip_key_prefix` is used only for keys created without a name. MySQL names
  its own keys (`INNODBKey-…`); MongoDB doesn't, so its keys get the prefix.

**Policy.** See `policies/`. A KMIP operation needs these transit paths:

| KMIP | Path | Capability |
|---|---|---|
| Create | `keys/<name>` | update |
| Register | `wrapping_key` + `keys/<name>/import` | read + update |
| Get | `keys/<name>` + `export/encryption-key/<name>/*` | read |
| GetAttributes, Activate, Locate by name | `keys/<name>` | read |
| Locate by attributes | `keys` + each `keys/<name>` | list + read |
| Encrypt / Decrypt | `encrypt/<name>`, `decrypt/<name>` | update |
| Sign / Verify | `sign/<name>`, `verify/<name>` | update |
| Revoke | `keys/<name>/soft-delete` | delete |
| Destroy | `keys/<name>` | delete |
| Query, DiscoverVersions | none | — |

Three rules matter:
- Grant `update`, not `create`, on `encrypt/*`. With `create`, Encrypt on a missing key would create it.
- Keys created over KMIP are exportable, so `read` on `export/*` is what guards key material.
- An `import/` entry in `keys` is transit's BYOK wrapping key, not a client key.
  Locate skips it.

## Namespaces

There are two ways to run with namespaces today.

### A. One listener, keys in tenant namespaces (central admin)

Cert auth and policies stay in root. Each role points into a tenant namespace.
`./setup-namespace.sh` sets this up for `tenant-a`:

```sh
bao namespace create tenant-a
bao secrets enable -ns=tenant-a -path=transit transit
bao policy write kmip-tenanta policies/kmip-tenanta.hcl     # in root; paths start with tenant-a/
bao write auth/cert/certs/tenanta certificate=@certs/ca.crt allowed_common_names=tenanta-kmip \
  token_policies=kmip-tenanta token_type=batch \
  kmip_transit_mount=tenant-a/transit kmip_key_prefix=ta-
```

```sh
(cd smoke && go run . -as tenanta)
./bao list -ns=tenant-a transit/keys        # ta-<uuid>, tenanta-smoke-key
```

- One port serves every tenant, and the audit log records the operations with `namespace: tenant-a/`.
- Tenant admins can't onboard KMIP clients themselves, because the roles and policies live in root.

### B. One listener per namespace (tenant self-service)

Everything lives inside the tenant namespace, and the listener points there:

```hcl
listener "kmip" {
  address    = "0.0.0.0:5697"                 # one port per namespace
  auth_mount = "tenant-b/auth/cert"
  # tls_* as above
}
```

```sh
bao auth enable -ns=tenant-b cert
bao secrets enable -ns=tenant-b transit
sed 's#transit-mysql/#transit/#' policies/kmip-mysql.hcl | bao policy write -ns=tenant-b kmip -
bao write -ns=tenant-b auth/cert/certs/app certificate=@certs/ca.crt allowed_common_names=... \
  token_policies=kmip token_type=batch kmip_transit_mount=transit
```

- Tenant admins manage their own roles and policies.
- The cost is one port per namespace.
- This setup isn't scripted here. The `namespace` subtest in
  `openbao/internal/kmip/integration_test.go` covers it.

**Not supported yet:** one listener with cert auth inside each tenant namespace.
The listener would need to pick the auth mount before login, for example from a
URI SAN like `openbao-kmip://tenant-a/auth/cert`. This is a candidate for step 3.

## Production setup checklist

1. **Server certificate.** Issue it from your server PKI, with SANs covering the
   name clients dial (load balancer or VIP), and `serverAuth` EKU. Use the same
   certificate on every node and reload it with SIGHUP.
2. **Client CA.** Use a dedicated KMIP-clients intermediate. Set it both as
   `tls_client_ca_file` and as the role's `certificate`. Do not use the
   company-wide client CA. To rotate it, put old and new CA in both places as a
   bundle.
3. **Client certificates.** Issue one per application, identified by CN or a URI SAN
   (for example `spiffe://corp/db/mysql-prod`), with `clientAuth` EKU. Revoke them
   with cert auth CRLs (`auth/cert/crls/*`) or OCSP (`ocsp_enabled=true`).
4. **Roles.** Use `token_type=batch` (one in-memory token per connection), a short
   `token_ttl` (the listener logs in again on its own), and optionally
   `token_bound_cidrs`.
5. **Load balancer.** Use TCP passthrough (layer 4). Terminating TLS there hides
   the client certificate. For real client IPs, enable PROXY protocol and set
   `proxy_protocol_behavior` on the listener.
6. **Audit.** Declare audit devices in the server config; this build rejects
   `bao audit enable`. See `kmip-listener.hcl`.

## Files

| File | Purpose |
|---|---|
| `build-bao.sh` | Build `./bao` from the OpenBao working tree |
| `gen-certs.sh` | Test CA, server cert, client certs |
| `kmip-listener.hcl` | KMIP listener and file audit device, merged into `-dev` |
| `start-bao.sh` | Dev server with `kmip-listener.hcl` |
| `setup-kmip.sh` | Transit mounts, policies, cert roles for mongodb and mysql |
| `setup-namespace.sh` | Namespace setup A for `tenant-a` |
| `policies/` | Transit ACLs per client |
| `smoke/` | Go KMIP client, no Docker needed |
| `docker-compose.yml`, `configs/` | Percona MongoDB and MySQL, unchanged from step 1 |

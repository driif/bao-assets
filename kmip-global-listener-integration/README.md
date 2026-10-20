# KMIP global listener: integration setup

Step 2 of the transit KMIP PoC. One `listener "kmip"` in the server config serves
every KMIP client. Clients log in through ordinary cert auth, and each KMIP
operation runs as normal transit requests under that token, so ACL policies,
audit, namespaces and standby forwarding all apply.

The database side (`docker-compose.yml`, `configs/`) is unchanged from
`../kmip-integration`: same port, same CA, same client cert CNs.

## What changed compared to `../kmip-integration`

| | Step 1 (`kmip-integration`) | Step 2 (this folder) |
|---|---|---|
| Where the server runs | Inside a transit mount: `bao write transit/config/kmip ...` | In the server config: `listener "kmip" { ... }` (`kmip-listener.hcl`) |
| Ports | One listener per mount | One listener for all mounts |
| TLS material | PEM strings stored in the mount | Files on disk, reloaded on SIGHUP like the `tcp` listener |
| Client identity | `transit/kmip/roles/*` matches the exact subject DN | Standard `auth/cert/certs/*` roles: CN, DNS/email/URI SAN, OU, CA... |
| Authorization | A per-role list of KMIP operations, valid for every key in the mount | Plain ACL policies on transit paths, down to single keys or key globs |
| Audit | None: the server read transit storage directly | Every operation is logged as the cert login plus the transit requests it makes |
| Which mount | The mount that runs the listener | Per cert role (`kmip_transit_mount`), or the listener's `default_transit_mount` |
| Keys created without a Name | Bare UUID | `kmip_key_prefix` + UUID, so prefix policies work |
| Revoke | No-op | Transit soft-delete; the key then reads back as `Deactivated` |
| Destroy | Deleted the key | `DELETE keys/<n>`; transit refuses it unless the key has `deletion_allowed=true` |
| HA | Only the node running the mount's listener | Runs on every node; standbys forward writes like HTTP |
| Error reasons | Mostly GeneralFailure | ItemNotFound, PermissionDenied, InvalidField... |

The ACL mapping (KMIP operation to transit path and capability) is in
`openbao/internal/kmip/doc.go` and in `website/content/docs/configuration/listener/kmip.mdx`.

## Quick start (no Docker)

```sh
./build-bao.sh            # builds ./bao from ~/Documents/work/bao/openbao (OPENBAO_SRC overrides)
./gen-certs.sh            # CA, server cert, client certs: mongodb, mysql, rogue
./start-bao.sh            # dev server :8200 (token root) + KMIP :5696 + audit.log; keep it running
./setup-kmip.sh           # in another shell: transit mounts, policies, cert auth roles
cd smoke && go run . -as mysql
```

Expected: every step reports `ok`, except Destroy, which fails because transit
keys have `deletion_allowed=false`. Then check isolation and rejection:

```sh
go run . -as mongodb -get mysql-smoke-key   # ItemNotFound: mongodb's role points at transit-mongodb
go run . -as rogue                          # Query ok; Create fails with PermissionDenied: no cert role matches CN=rogue-kmip
```

To see the trail, run `tail -f audit.log`. A KMIP Create appears as
`auth/cert/login` and then `update transit-mysql/keys/<name>`.

Use the pinned toolchain for `go run` if your default `go` is newer:
`GOTOOLCHAIN=go$(cat ~/Documents/work/bao/openbao/.go-version) go run . -as mysql`.

## With Percona MongoDB and MySQL

After the quick start (server running, `setup-kmip.sh` done):

```sh
docker compose up -d
docker compose logs -f percona-mongodb | grep -i kmip     # "Master encryption key has been created..."
BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root ./bao list transit-mongodb/keys   # mongodb-<uuid>
BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root ./bao list transit-mysql/keys
```

Two things to expect:
- **MySQL creates its key lazily.** `transit-mysql/keys` stays empty until the
  first encrypted table is written. Then MySQL registers its key under its own
  name (`INNODBKey-<server uuid>-1`), so `kmip_key_prefix` does not apply to it.
  MongoDB creates its key without a name at startup, so its key does get the
  prefix (`mongodb-<uuid>`).
- **An `import/` entry appears in the key list** after the first Register. It is
  transit's own BYOK wrapping key (`policy/import/wrapping-key`), not a client
  key, and Locate skips it.

The MySQL and MongoDB checks in `../kmip-integration/README.md` apply as-is.
The only difference is that keys appear in `transit-mongodb` and `transit-mysql`
instead of `transit`. Use `docker compose down -v` to start clean.

Things to test by hand:
- **Least privilege.** Remove the `export/encryption-key/*` block from a policy and
  `bao policy write` it again. Get then fails with PermissionDenied, and the
  message names the path and capability that were missing.
- **Narrowing to a prefix.** Change `keys/*` to `keys/mysql-*` in `policies/kmip-mysql.hcl`.
  Keys the database creates without a name still work because they get the role's
  prefix. Named keys only work if their names match.
- **Token lifetime.** Set `token_ttl=30s` on a role. The connection logs in again on its own.
- **Restart.** Restart the server. Clients reconnect and log in again, and nothing KMIP-specific is lost because nothing KMIP-specific is stored.

## Setting it up as an admin

### 1. Certificates

There are three certificate roles:

1. **The server certificate** (`tls_cert_file` / `tls_key_file`)
   - Issued by your normal server PKI.
   - Its SANs must cover the name clients dial: the load balancer or VIP DNS name, plus node names if clients reach nodes directly. Add `extendedKeyUsage=serverAuth`.
   - Use the same name on every node. After rotating it, send SIGHUP; no restart is needed.
   - Clients trust it through their own CA setting (`serverCAFile` in MongoDB, `server_ca` in MySQL).
2. **The client CA** (`tls_client_ca_file` on the listener and `certificate=` on the cert role)
   - Use a dedicated "KMIP clients" intermediate, not the company-wide client CA. Otherwise every mTLS certificate in the company completes the KMIP handshake and only cert auth stops it.
   - The listener checks the chain during the TLS handshake. Cert auth checks it again, together with the role's constraints, at login.
   - To rotate the CA, put the old and new CA in both places as a bundle, reissue the client certs, then drop the old CA.
3. **The client certificates**, one per application identity (for example one per database cluster)
   - The identity goes into the subject or SANs, and a cert role matches on it. Options:
     - CN: `allowed_common_names=mysql-kmip`
     - URI SAN: `allowed_uri_sans=spiffe://corp/db/mysql-prod`. This is a good fit if you already issue SPIFFE-style identities; it is now an identity check only, not routing.
     - OU or DNS SAN: `allowed_organizational_units`, `allowed_dns_sans`
   - Give certs `extendedKeyUsage=clientAuth`.
   - Rotating a client cert needs no OpenBao change as long as the issuer and the matching field stay the same.
   - Revocation uses cert auth's CRL support (`auth/cert/crls/<name>`) or OCSP (`ocsp_enabled=true` on the role).

Keep role constraints mutually exclusive. The client sends no role name at
login, so cert auth tries every role. A certificate that matches two roles
makes the choice ambiguous, and a role with no constraint matches every
certificate from its CA.

### 2. Server config (every node)

```hcl
listener "kmip" {
  address            = "0.0.0.0:5696"
  tls_cert_file      = "/etc/openbao/tls/kmip.crt"
  tls_key_file       = "/etc/openbao/tls/kmip.key"
  tls_client_ca_file = "/etc/openbao/tls/kmip-clients-ca.pem"
  auth_mount         = "auth/cert"        # or "<namespace>/auth/cert"
}
```

- **Load balancer.** Put a TCP (layer 4) load balancer in front, with TLS passthrough. If it terminated TLS, OpenBao would never see the client certificate. To keep the client IP for audit and `token_bound_cidrs`, enable the PROXY protocol on the load balancer and set `proxy_protocol_behavior` on the listener.
- **Namespaces.** One listener serves one namespace, the one in `auth_mount`. Clients in other namespaces need another `listener "kmip"` on another port.

### 3. In OpenBao (API or Terraform, nothing KMIP-specific except two role fields)

```sh
bao secrets enable -path=transit-mysql transit          # or reuse an existing transit mount
bao policy write kmip-mysql policies/kmip-mysql.hcl
bao auth enable cert                                     # or reuse an existing cert mount
bao write auth/cert/certs/mysql-prod \
  certificate=@kmip-clients-ca.pem \
  allowed_common_names=mysql-kmip \
  token_policies=kmip-mysql \
  token_type=batch token_ttl=1h \
  token_bound_cidrs=10.20.0.0/24 \
  kmip_transit_mount=transit-mysql \
  kmip_key_prefix=mysql-
```

- **`token_type=batch`.** The listener holds one token per connection, in memory only, so batch tokens avoid a storage write per connection.
- **Policies.** Start from `policies/*.hcl`. Grant `update`, not `create`, on `encrypt/*`; with `create`, Encrypt on a missing key would create it.
- **Keys created over KMIP are exportable.** Create and Register set `exportable=true` so Get can return the key material, and transit cannot undo that. `read` on `export/*` is therefore the real guard on key material: leave it out for clients that only encrypt or decrypt.

### 4. Client side

Point the database at the load balancer name on port 5696. Give it the server
CA and its client certificate. See `configs/` for MongoDB and MySQL.

## Files

| File | Purpose |
|---|---|
| `build-bao.sh` | Builds `./bao` from the checkout's working tree |
| `gen-certs.sh` | Test CA, server cert, and client certs `mongodb`, `mysql`, `rogue` |
| `kmip-listener.hcl` | The `listener "kmip"` block and a file audit device, merged into `-dev` |
| `start-bao.sh` | Dev server plus `kmip-listener.hcl` |
| `setup-kmip.sh` | Transit mounts, policies, cert auth roles |
| `policies/` | Plain transit ACLs for each client |
| `smoke/` | Go KMIP client that exercises the listener without Docker |
| `docker-compose.yml`, `configs/` | Percona MongoDB and MySQL, unchanged from step 1 |

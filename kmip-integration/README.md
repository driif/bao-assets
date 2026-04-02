move bao executable with name 'bao' here

start bao server:
`./bao server -dev -dev-root-token-id=root`

gen certs:
```
chmod +x gen-certs.sh
./gen-certs.sh
```

configure bao kmip:
```
chmod +x setup-kmip.sh
./setup-kmip.sh
```

start docker compose with percona's mysql and mongodb:
`docker compose up -d`
`docker compose down -v` - clears volume

verify mongodb:
logs:
```
2026-04-02 13:33:19 {"t":{"$date":"2026-04-02T11:33:19.633+00:00"},"s":"I",  "c":"CONTROL",  "id":21951,   "ctx":"initandlisten","msg":"Options set by command line","attr":{"options":{"config":"/etc/mongod.conf","net":{"bindIp":"0.0.0.0","port":27017},"security":{"enableEncryption":true,"kmip":{"clientCertificateFile":"/certs/mongodb-client-combined.pem","port":5696,"serverCAFile":"/certs/ca.crt","serverName":"host.docker.internal"}},"storage":{"dbPath":"/data/db","engine":"wiredTiger"}}}}
2026-04-02 13:33:19 {"t":{"$date":"2026-04-02T11:33:19.633+00:00"},"s":"W",  "c":"NETWORK",  "id":11621101,"ctx":"initandlisten","msg":"Overriding max connections to honor `capMemoryConsumptionForPreAuthBuffers` settings","attr":{"limit":100300}}
2026-04-02 13:33:19 {"t":{"$date":"2026-04-02T11:33:19.634+00:00"},"s":"I",  "c":"STORAGE",  "id":22297,   "ctx":"initandlisten","msg":"Using the XFS filesystem is strongly recommended with the WiredTiger storage engine. See http://dochub.mongodb.org/core/prodnotes-filesystem","tags":["startupWarnings"]}
2026-04-02 13:33:19 {"t":{"$date":"2026-04-02T11:33:19.648+00:00"},"s":"I",  "c":"STORAGE",  "id":29116,   "ctx":"initandlisten","msg":"Master encryption key has been created on the key management facility","attr":{"keyManagementFacilityType":"KMIP server","keyIdentifier":{"kmipKeyIdentifier":"0d82a3e8-8421-4b87-98ba-2017724593fc"}}}
```

check mongodb and transit keys
```
# Connect and insert encrypted data
docker exec -it percona-mongodb mongosh --eval "
  use testdb;
  db.secrets.insertOne({ message: 'Encrypted at rest!' });
  db.secrets.find().pretty();
"

# Verify the key appeared in OpenBao
BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root bao list transit/keys
```

verify mongodb server status
`docker exec -it percona-mongodb mongosh --eval "db.adminCommand({serverStatus:1}).encryptionAtRest"`

should get same key:
```
{
  encryptionEnabled: true,
  encryptionCipherMode: 'AES256-CBC',
  encryptionKeyId: { kmip: { keyId: '0d82a3e8-8421-4b87-98ba-2017724593fc' } }
}
```

verify mysql:

check mysql encryption and transit keys:
```
# Connect and insert encrypted data
docker exec -it percona-mysql mysql -uroot -prootpass testdb -e "
  CREATE TABLE IF NOT EXISTS secrets (id INT AUTO_INCREMENT PRIMARY KEY, message VARCHAR(255)) ENCRYPTION='Y';
  INSERT INTO secrets (message) VALUES ('Encrypted at rest!');
  SELECT * FROM secrets;
"
```

Verify the key appeared in OpenBao
`BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root bao list transit/keys`


check the encryption key:
`docker exec -it percona-mysql mysql -uroot -prootpass -e "SELECT * FROM performance_schema.keyring_keys;"`

verify mysql encryption status:
```
docker exec -it percona-mysql mysql -uroot -prootpass -e "
  SELECT TABLE_NAME, CREATE_OPTIONS FROM information_schema.TABLES
  WHERE TABLE_SCHEMA='testdb' AND CREATE_OPTIONS LIKE '%ENCRYPTION%';
"
```

should show:
```
+------------+----------------+
| TABLE_NAME | CREATE_OPTIONS |
+------------+----------------+
| secrets    | ENCRYPTION="Y" |
+------------+----------------+
```
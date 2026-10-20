// kmip-smoke drives the OpenBao KMIP listener the way a database would, without Docker.
//
//	go run . -as mysql            # full flow as the mysql client
//	go run . -as mongodb -get <id> # cross-tenant read: must fail
//	go run . -as rogue            # cert no role matches: must fail
package main

import (
	"flag"
	"fmt"
	"log"
	"os"

	kmip "github.com/ovh/kmip-go"
	"github.com/ovh/kmip-go/kmipclient"
	"github.com/ovh/kmip-go/ttlv"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:5696", "KMIP listener address")
	certs := flag.String("certs", "../certs", "directory from gen-certs.sh")
	as := flag.String("as", "mysql", "client cert to use: mongodb, mysql or rogue")
	get := flag.String("get", "", "only Get this key id and exit")
	flag.Parse()

	c, err := kmipclient.Dial(*addr,
		kmipclient.WithRootCAFile(*certs+"/ca.crt"),
		kmipclient.WithServerName("localhost"),
		kmipclient.WithClientCertFiles(*certs+"/"+*as+"-client.crt", *certs+"/"+*as+"-client.key"),
	)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer c.Close()

	if *get != "" {
		_, err := c.Get(*get).Exec()
		report("Get "+*get, err)
		return
	}

	_, err = c.Query().Operations().Exec()
	report("Query (answered by the listener, no login)", err)

	named := *as + "-smoke-key"
	created, err := c.Create().AES(256, kmip.CryptographicUsageEncrypt|kmip.CryptographicUsageDecrypt).WithName(named).Exec()
	if !report("Create AES-256 named "+named, err) {
		os.Exit(1)
	}
	id := created.UniqueIdentifier

	nameless, err := c.Create().AES(256, kmip.CryptographicUsageEncrypt).Exec()
	if report("Create AES-256 without a name", err) {
		fmt.Printf("     -> id %s (role's kmip_key_prefix + UUID)\n", nameless.UniqueIdentifier)
	}

	got, err := c.Get(id).Exec()
	if report("Get key material", err) {
		fmt.Printf("     -> %T\n", got.Object)
	}

	enc, err := c.Encrypt(id).Data([]byte("hello kmip")).Exec()
	if report("Encrypt", err) {
		dec, err := c.Decrypt(id).Data(enc.Data).Exec()
		if report("Decrypt", err) {
			fmt.Printf("     -> %q\n", dec.Data)
		}
	}

	byName, err := c.Locate().WithName(named).Exec()
	if report("Locate by name", err) {
		fmt.Printf("     -> %v\n", byName.UniqueIdentifier)
	}
	all, err := c.Locate().WithObjectType(kmip.ObjectTypeSymmetricKey).Exec()
	if report("Locate all symmetric keys", err) {
		fmt.Printf("     -> %v\n", all.UniqueIdentifier)
	}

	_, err = c.Revoke(nameless.UniqueIdentifier).Exec()
	report("Revoke the nameless key (transit soft-delete)", err)
	attrs, err := c.GetAttributes(nameless.UniqueIdentifier).WithAttributes(kmip.AttributeNameState).Exec()
	if report("GetAttributes State after Revoke", err) {
		for _, a := range attrs.Attribute {
			if st, ok := a.AttributeValue.(kmip.State); ok {
				fmt.Printf("     -> %s\n", ttlv.EnumStr(st))
			}
		}
	}

	_, err = c.Destroy(id).Exec()
	report("Destroy (expected to fail: transit deletion_allowed=false)", err)

	fmt.Printf("\nkey %s stays in transit; try: go run . -as <other client> -get %s\n", id, id)
}

func report(what string, err error) bool {
	if err != nil {
		fmt.Printf("FAIL %s: %v\n", what, err)
		return false
	}
	fmt.Printf("ok   %s\n", what)
	return true
}

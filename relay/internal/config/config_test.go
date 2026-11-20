package config

import "testing"

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadDefaults(t *testing.T) {
	c, err := Load(env(map[string]string{
		"RELAY_PUBLIC_HOST":  "relay.example.org",
		"RELAY_ENROLL_TOKEN": "0123456789abcdef0123456789abcdef",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":8080" || c.DataDir != "/data" || c.MaxAccounts != 4 || c.APNsKeyFile != "/run/secrets/apns.p8" {
		t.Fatalf("defaults: %+v", c)
	}
	if c.APNsConfigured() || c.TestMode || c.APNsEndpointOverride != "" {
		t.Fatalf("apns: %+v", c)
	}
	if len(c.TrustedProxies) != 3 {
		t.Fatalf("proxies: %v", c.TrustedProxies)
	}
}

func TestLoadRejectsShortTokenAndMissingHost(t *testing.T) {
	if _, err := Load(env(map[string]string{"RELAY_PUBLIC_HOST": "h", "RELAY_ENROLL_TOKEN": "short"})); err == nil {
		t.Fatal("accepted a short token")
	}
	if _, err := Load(env(map[string]string{"RELAY_ENROLL_TOKEN": "0123456789abcdef0123456789abcdef"})); err == nil {
		t.Fatal("accepted no public host")
	}
}

func TestEndpointOverrideOnlyInTestMode(t *testing.T) {
	values := map[string]string{
		"RELAY_PUBLIC_HOST":      "h",
		"RELAY_ENROLL_TOKEN":     "0123456789abcdef0123456789abcdef",
		"APNS_ENDPOINT_OVERRIDE": "https://127.0.0.1:1",
	}
	c, err := Load(env(values))
	if err != nil || c.APNsEndpointOverride != "" {
		t.Fatalf("override without test mode: %+v %v", c, err)
	}
	values["RELAY_TEST_MODE"] = "1"
	c, err = Load(env(values))
	if err != nil || c.APNsEndpointOverride != "https://127.0.0.1:1" {
		t.Fatalf("override in test mode: %+v %v", c, err)
	}
}

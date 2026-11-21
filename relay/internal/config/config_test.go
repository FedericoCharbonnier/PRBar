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
	if c.Listen != ":8080" || c.DataDir != "/data" || c.MaxAccounts != 4 {
		t.Fatalf("defaults: %+v", c)
	}
	if c.PushConfigured() || c.TestMode || c.WebPushTestEndpoint != "" || c.VAPIDSubject != "https://relay.example.org" {
		t.Fatalf("push: %+v", c)
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

func TestVAPID(t *testing.T) {
	values := map[string]string{
		"RELAY_PUBLIC_HOST":  "h",
		"RELAY_ENROLL_TOKEN": "0123456789abcdef0123456789abcdef",
		"VAPID_PRIVATE_KEY":  "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
		"VAPID_SUBJECT":      "mailto:ops@example.org",
	}
	c, err := Load(env(values))
	if err != nil || !c.PushConfigured() || len(c.VAPIDPrivateKey) != 32 || c.VAPIDPrivateKey[0] != 1 ||
		c.VAPIDSubject != "mailto:ops@example.org" {
		t.Fatalf("vapid: %+v %v", c, err)
	}
	for _, bad := range []string{"AQID", "not base64!", "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="} {
		values["VAPID_PRIVATE_KEY"] = bad
		if _, err := Load(env(values)); err == nil {
			t.Fatalf("accepted VAPID_PRIVATE_KEY=%q", bad)
		}
	}
}

func TestWebPushTestEndpointOnlyInTestMode(t *testing.T) {
	values := map[string]string{
		"RELAY_PUBLIC_HOST":     "h",
		"RELAY_ENROLL_TOKEN":    "0123456789abcdef0123456789abcdef",
		"WEBPUSH_TEST_ENDPOINT": "http://127.0.0.1:1/push/",
	}
	c, err := Load(env(values))
	if err != nil || c.WebPushTestEndpoint != "" {
		t.Fatalf("test endpoint without test mode: %+v %v", c, err)
	}
	values["RELAY_TEST_MODE"] = "1"
	c, err = Load(env(values))
	if err != nil || c.WebPushTestEndpoint != "http://127.0.0.1:1/push/" {
		t.Fatalf("test endpoint in test mode: %+v %v", c, err)
	}
}

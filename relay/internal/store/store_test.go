package store

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func open(t *testing.T, path string, clock *fakeClock) *Store {
	t.Helper()
	s, err := Open(path, 2, clock.now)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestAccountsAndLimit(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1_800_000_000, 0)}
	s := open(t, filepath.Join(t.TempDir(), "relay.db"), clock)
	defer s.Close()
	if err := s.CreateAccount("a1", []byte("k1")); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateAccount("a1", []byte("k1")); !errors.Is(err, ErrExists) {
		t.Fatalf("duplicate: %v", err)
	}
	if err := s.CreateAccount("a2", []byte("k2")); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateAccount("a3", []byte("k3")); !errors.Is(err, ErrTooManyAccounts) {
		t.Fatalf("limit: %v", err)
	}
	account, ok, err := s.Account("a2")
	if err != nil || !ok || !bytes.Equal(account.MacRelayKey, []byte("k2")) {
		t.Fatalf("account: %+v %v %v", account, ok, err)
	}
	if _, ok, _ := s.Account("nope"); ok {
		t.Fatal("found a missing account")
	}
}

func TestDevicesTokensAndRemoval(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1_800_000_000, 0)}
	s := open(t, filepath.Join(t.TempDir(), "relay.db"), clock)
	defer s.Close()
	if err := s.AddDevice("a1", "d1", []byte("key")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("device without account: %v", err)
	}
	_ = s.CreateAccount("a1", []byte("k"))
	for i := 0; i < MaxDevicesPerAccount; i++ {
		if err := s.AddDevice("a1", string(rune('a'+i)), []byte("key")); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.AddDevice("a1", "z", []byte("key")); !errors.Is(err, ErrTooManyDevices) {
		t.Fatalf("device limit: %v", err)
	}
	sub := WebPush{Endpoint: "https://web.push.apple.com/abc", P256dh: []byte{4, 1}, Auth: []byte{2}}
	if err := s.SetWebPush("a1", "a", sub); err != nil {
		t.Fatal(err)
	}
	if err := s.PutMailbox("a1", "a", "home", []byte("blob")); err != nil {
		t.Fatal(err)
	}
	device, ok, _ := s.Device("a1", "a")
	if !ok || device.WebPush == nil || device.WebPush.Endpoint != sub.Endpoint || string(device.WebPush.Auth) != "\x02" {
		t.Fatalf("device: %+v", device)
	}
	// Solo se borra si sigue siendo la misma suscripción (el teléfono pudo registrar otra mientras tanto).
	if err := s.ClearWebPush("a1", "a", "https://web.push.apple.com/other"); err != nil {
		t.Fatal(err)
	}
	if device, _, _ = s.Device("a1", "a"); device.WebPush == nil {
		t.Fatal("cleared another subscription")
	}
	if err := s.ClearWebPush("a1", "a", sub.Endpoint); err != nil {
		t.Fatal(err)
	}
	if device, _, _ = s.Device("a1", "a"); device.WebPush != nil {
		t.Fatal("subscription not cleared")
	}
	if err := s.RemoveDevice("a1", "a"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.Device("a1", "a"); ok {
		t.Fatal("device not removed")
	}
	if items, _ := s.Mailbox("a1", "a"); len(items) != 0 {
		t.Fatal("mailbox not removed with the device")
	}
	list, err := s.Devices("a1")
	if err != nil || len(list) != MaxDevicesPerAccount-1 {
		t.Fatalf("devices: %v %v", list, err)
	}
}

func TestMailboxSlotsSizeAndTTL(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1_800_000_000, 0)}
	s := open(t, filepath.Join(t.TempDir(), "relay.db"), clock)
	defer s.Close()
	_ = s.CreateAccount("a1", []byte("k"))
	_ = s.AddDevice("a1", "d1", []byte("key"))
	if err := s.PutMailbox("a1", "nope", "home", []byte("x")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown device: %v", err)
	}
	for _, slot := range []string{"s1", "s2", "s3", "s4"} {
		if err := s.PutMailbox("a1", "d1", slot, []byte(slot)); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.PutMailbox("a1", "d1", "s5", []byte("x")); !errors.Is(err, ErrMailboxFull) {
		t.Fatalf("slot limit: %v", err)
	}
	if err := s.PutMailbox("a1", "d1", "s1", []byte("new")); err != nil {
		t.Fatalf("replace: %v", err)
	}
	if err := s.PutMailbox("a1", "d1", "s2", make([]byte, MaxMailboxBlob+1)); !errors.Is(err, ErrBlobTooLarge) {
		t.Fatalf("size: %v", err)
	}
	items, _ := s.Mailbox("a1", "d1")
	if len(items) != 4 || items[0].Slot != "s1" || string(items[0].Blob) != "new" {
		t.Fatalf("items: %+v", items)
	}
	clock.t = clock.t.Add(MailboxTTL - time.Hour)
	_ = s.PutMailbox("a1", "d1", "s2", []byte("fresh"))
	clock.t = clock.t.Add(2 * time.Hour)
	if items, _ := s.Mailbox("a1", "d1"); len(items) != 1 || items[0].Slot != "s2" {
		t.Fatalf("expired items still visible: %+v", items)
	}
	removed, err := s.SweepMailbox()
	if err != nil || removed != 3 {
		t.Fatalf("sweep: %d %v", removed, err)
	}
}

func TestReopenKeepsEverything(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1_800_000_000, 0)}
	path := filepath.Join(t.TempDir(), "relay.db")
	s := open(t, path, clock)
	_ = s.CreateAccount("a1", []byte("k"))
	_ = s.AddDevice("a1", "d1", []byte("key"))
	_ = s.PutMailbox("a1", "d1", "home", []byte("blob"))
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s = open(t, path, clock)
	defer s.Close()
	if _, ok, _ := s.Account("a1"); !ok {
		t.Fatal("account lost")
	}
	if _, ok, _ := s.Device("a1", "d1"); !ok {
		t.Fatal("device lost")
	}
	if items, _ := s.Mailbox("a1", "d1"); len(items) != 1 {
		t.Fatal("mailbox lost")
	}
}

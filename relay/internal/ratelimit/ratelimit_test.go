package ratelimit

import (
	"testing"
	"time"
)

func TestBucket(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	b := NewBucket(50, 200, now)
	allowed := 0
	for i := 0; i < 300; i++ {
		if b.Allow(now, 1) {
			allowed++
		}
	}
	if allowed != 200 {
		t.Fatalf("burst: %d", allowed)
	}
	if !b.Allow(now.Add(time.Second), 50) || b.Allow(now.Add(time.Second), 1) {
		t.Fatal("refill")
	}
}

func TestKeyed(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	k := NewKeyed(10.0/60, 10, func() time.Time { return now })
	for i := 0; i < 10; i++ {
		if !k.Allow("1.2.3.4") {
			t.Fatalf("upgrade %d refused", i)
		}
	}
	if k.Allow("1.2.3.4") {
		t.Fatal("11th upgrade allowed")
	}
	if !k.Allow("5.6.7.8") {
		t.Fatal("other IP refused")
	}
	now = now.Add(time.Minute)
	if !k.Allow("1.2.3.4") {
		t.Fatal("no refill after a minute")
	}
}

func TestLockout(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	l := NewLockout(5, 10*time.Minute, 15*time.Minute, func() time.Time { return now })
	for i := 0; i < 4; i++ {
		if l.Fail("ip") || l.Blocked("ip") {
			t.Fatalf("blocked after %d failures", i+1)
		}
	}
	if !l.Fail("ip") || !l.Blocked("ip") {
		t.Fatal("not blocked after 5 failures")
	}
	now = now.Add(14 * time.Minute)
	if !l.Blocked("ip") {
		t.Fatal("unblocked too soon")
	}
	now = now.Add(2 * time.Minute)
	if l.Blocked("ip") {
		t.Fatal("still blocked after 15 min")
	}
	// Fallos espaciados más que la ventana no bloquean.
	for i := 0; i < 6; i++ {
		now = now.Add(3 * time.Minute)
		l.Fail("slow")
	}
	if l.Blocked("slow") {
		t.Fatal("spaced failures blocked")
	}
}

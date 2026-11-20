// Package ratelimit tiene los límites del relay (spec P.10): token buckets por conexión y por IP, y bloqueos
// por intentos fallidos. Todo con un reloj inyectable.
package ratelimit

import (
	"sync"
	"time"
)

// Bucket es un token bucket: `rate` por segundo, hasta `burst`.
type Bucket struct {
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
}

// NewBucket arranca lleno.
func NewBucket(rate, burst float64, now time.Time) *Bucket {
	return &Bucket{rate: rate, burst: burst, tokens: burst, last: now}
}

// Allow consume n tokens si hay.
func (b *Bucket) Allow(now time.Time, n float64) bool {
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens += elapsed * b.rate
		if b.tokens > b.burst {
			b.tokens = b.burst
		}
		b.last = now
	}
	if b.tokens < n {
		return false
	}
	b.tokens -= n
	return true
}

// Keyed es un bucket por clave (p. ej. por IP o por cuenta), con un tope de claves para no crecer sin límite.
type Keyed struct {
	mu      sync.Mutex
	rate    float64
	burst   float64
	maxKeys int
	now     func() time.Time
	buckets map[string]*Bucket
}

// NewKeyed crea un limitador por clave.
func NewKeyed(rate, burst float64, now func() time.Time) *Keyed {
	return &Keyed{rate: rate, burst: burst, maxKeys: 10_000, now: now, buckets: map[string]*Bucket{}}
}

// Allow consume un token de la clave.
func (k *Keyed) Allow(key string) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	now := k.now()
	b, ok := k.buckets[key]
	if !ok {
		if len(k.buckets) >= k.maxKeys {
			k.prune(now)
			if len(k.buckets) >= k.maxKeys {
				return false
			}
		}
		b = NewBucket(k.rate, k.burst, now)
		k.buckets[key] = b
	}
	return b.Allow(now, 1)
}

// prune saca los buckets que ya se llenaron de nuevo (equivalen a uno nuevo).
func (k *Keyed) prune(now time.Time) {
	for key, b := range k.buckets {
		if b.tokens+now.Sub(b.last).Seconds()*b.rate >= b.burst {
			delete(k.buckets, key)
		}
	}
}

// Lockout bloquea una clave (IP) por `block` después de `max` fallos dentro de `window`.
type Lockout struct {
	mu       sync.Mutex
	max      int
	window   time.Duration
	block    time.Duration
	now      func() time.Time
	failures map[string][]time.Time
	blocked  map[string]time.Time
}

// NewLockout crea un bloqueo por fallos.
func NewLockout(maxFailures int, window, block time.Duration, now func() time.Time) *Lockout {
	return &Lockout{max: maxFailures, window: window, block: block, now: now, failures: map[string][]time.Time{},
		blocked: map[string]time.Time{}}
}

// Blocked dice si la clave está bloqueada ahora.
func (l *Lockout) Blocked(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	until, ok := l.blocked[key]
	if !ok {
		return false
	}
	if l.now().Before(until) {
		return true
	}
	delete(l.blocked, key)
	return false
}

// Fail anota un fallo; devuelve true si con este la clave quedó bloqueada.
func (l *Lockout) Fail(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	recent := l.failures[key][:0]
	for _, t := range l.failures[key] {
		if now.Sub(t) < l.window {
			recent = append(recent, t)
		}
	}
	recent = append(recent, now)
	if len(recent) >= l.max {
		l.blocked[key] = now.Add(l.block)
		delete(l.failures, key)
		return true
	}
	l.failures[key] = recent
	if len(l.failures) > 10_000 {
		for k, times := range l.failures {
			if len(times) == 0 || now.Sub(times[len(times)-1]) >= l.window {
				delete(l.failures, k)
			}
		}
	}
	return false
}

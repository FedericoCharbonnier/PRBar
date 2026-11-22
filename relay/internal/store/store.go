// Package store guarda lo poco que el relay necesita recordar (spec P.10), en bbolt:
//
//	accounts: accountId → {macRelayKey, createdAt, macSeen}
//	devices:  accountId/deviceId → {relayKey, webPush?, lastSeen}
//	mailbox:  accountId/deviceId/slot → {blob, at} (TTL 7 días)
//
// Nada de esto es secreto salvo los endpoints de Web Push (con ellos cualquiera podría mandar pushes que el teléfono
// no puede descifrar): claves públicas, suscripciones de push y blobs cifrados de punta a punta.
package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"time"

	bolt "go.etcd.io/bbolt"
)

var (
	bucketAccounts = []byte("accounts")
	bucketDevices  = []byte("devices")
	bucketMailbox  = []byte("mailbox")
)

// Límites (spec P.4 y P.10).
const (
	MaxDevicesPerAccount = 10
	MaxMailboxSlots      = 4
	MailboxTTL           = 7 * 24 * time.Hour
)

var (
	ErrTooManyAccounts = errors.New("store: account limit reached")
	ErrTooManyDevices  = errors.New("store: device limit reached")
	ErrNotFound        = errors.New("store: not found")
	ErrMailboxFull     = errors.New("store: mailbox slot limit reached")
	ErrExists          = errors.New("store: already exists")
)

// Account es una Mac inscrita. MacSeen es la última vez que la Mac estuvo conectada (cero en cuentas de antes de
// este campo: cuenta CreatedAt).
type Account struct {
	MacRelayKey []byte    `json:"macRelayKey"`
	CreatedAt   time.Time `json:"createdAt"`
	MacSeen     time.Time `json:"macSeen,omitempty"`
}

// lastSeen: la última señal de vida de la Mac de la cuenta.
func (a Account) lastSeen() time.Time {
	if a.MacSeen.After(a.CreatedAt) {
		return a.MacSeen
	}
	return a.CreatedAt
}

// Device es un teléfono dado de alta por su Mac. Los campos de APNs de versiones anteriores se ignoran al leer.
type Device struct {
	RelayKey []byte    `json:"relayKey"`
	WebPush  *WebPush  `json:"webPush,omitempty"`
	LastSeen time.Time `json:"lastSeen"`
}

// WebPush es la suscripción de push del navegador del teléfono (spec W.6), ya validada por el hub.
type WebPush struct {
	Endpoint string `json:"endpoint"`
	P256dh   []byte `json:"p256dh"`
	Auth     []byte `json:"auth"`
}

// DeviceEntry es una fila de la lista de dispositivos.
type DeviceEntry struct {
	ID       string
	LastSeen time.Time
}

// MailboxItem es un blob del buzón.
type MailboxItem struct {
	Slot string    `json:"slot"`
	Blob []byte    `json:"blob"`
	At   time.Time `json:"at"`
}

// Store envuelve la base.
type Store struct {
	db          *bolt.DB
	now         func() time.Time
	maxAccounts int
}

// Open abre (o crea) la base en path.
func Open(path string, maxAccounts int, now func() time.Time) (*Store, error) {
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: 2 * time.Second})
	if err != nil {
		return nil, err
	}
	err = db.Update(func(tx *bolt.Tx) error {
		for _, name := range [][]byte{bucketAccounts, bucketDevices, bucketMailbox} {
			if _, err := tx.CreateBucketIfNotExists(name); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db, now: now, maxAccounts: maxAccounts}, nil
}

// Close cierra la base.
func (s *Store) Close() error { return s.db.Close() }

func deviceKey(acct, dev string) []byte { return []byte(acct + "/" + dev) }

func mailboxPrefix(acct, dev string) []byte { return []byte(acct + "/" + dev + "/") }

func get[T any](b *bolt.Bucket, key []byte) (T, bool, error) {
	var value T
	raw := b.Get(key)
	if raw == nil {
		return value, false, nil
	}
	err := json.Unmarshal(raw, &value)
	return value, err == nil, err
}

func put(b *bolt.Bucket, key []byte, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return b.Put(key, raw)
}

// CreateAccount inscribe una Mac. Falla con ErrTooManyAccounts al llegar al tope.
func (s *Store) CreateAccount(id string, macKey []byte) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketAccounts)
		if b.Get([]byte(id)) != nil {
			return ErrExists
		}
		count := 0
		if err := b.ForEach(func(_, _ []byte) error {
			count++
			return nil
		}); err != nil {
			return err
		}
		if count >= s.maxAccounts {
			return ErrTooManyAccounts
		}
		return put(b, []byte(id), Account{MacRelayKey: macKey, CreatedAt: s.now().UTC()})
	})
}

// AccountCount cuenta las cuentas.
func (s *Store) AccountCount() (int, error) {
	n := 0
	err := s.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket(bucketAccounts).ForEach(func(_, _ []byte) error {
			n++
			return nil
		})
	})
	return n, err
}

// Account devuelve una cuenta.
func (s *Store) Account(id string) (Account, bool, error) {
	var (
		account Account
		ok      bool
	)
	err := s.db.View(func(tx *bolt.Tx) error {
		var err error
		account, ok, err = get[Account](tx.Bucket(bucketAccounts), []byte(id))
		return err
	})
	return account, ok, err
}

// TouchAccount anota que la Mac de la cuenta está (o estuvo hasta ahora) conectada.
func (s *Store) TouchAccount(id string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketAccounts)
		account, ok, err := get[Account](b, []byte(id))
		if err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		account.MacSeen = s.now().UTC()
		return put(b, []byte(id), account)
	})
}

// DeleteAccount borra la cuenta con sus dispositivos (suscripciones de push incluidas) y su buzón. Una cuenta que ya
// no existe no es un error.
func (s *Store) DeleteAccount(id string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		if err := tx.Bucket(bucketAccounts).Delete([]byte(id)); err != nil {
			return err
		}
		// Los ids tienen largo fijo: el prefijo "id/" no puede tocar otra cuenta.
		prefix := []byte(id + "/")
		if err := deletePrefix(tx.Bucket(bucketDevices), prefix); err != nil {
			return err
		}
		return deletePrefix(tx.Bucket(bucketMailbox), prefix)
	})
}

// IdleAccounts lista las cuentas cuya Mac no se conecta desde antes de cutoff.
func (s *Store) IdleAccounts(cutoff time.Time) ([]string, error) {
	var out []string
	err := s.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket(bucketAccounts).ForEach(func(k, v []byte) error {
			var account Account
			if err := json.Unmarshal(v, &account); err != nil {
				return err
			}
			if account.lastSeen().Before(cutoff) {
				out = append(out, string(k))
			}
			return nil
		})
	})
	return out, err
}

// Ping comprueba que la base responde (para /healthz).
func (s *Store) Ping() error {
	return s.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket(bucketAccounts) == nil {
			return errors.New("store: accounts bucket missing")
		}
		return nil
	})
}

// AddDevice da de alta (o reemplaza la clave de) un dispositivo.
func (s *Store) AddDevice(acct, dev string, relayKey []byte) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		if tx.Bucket(bucketAccounts).Get([]byte(acct)) == nil {
			return ErrNotFound
		}
		b := tx.Bucket(bucketDevices)
		key := deviceKey(acct, dev)
		if b.Get(key) == nil {
			count := 0
			c := b.Cursor()
			prefix := []byte(acct + "/")
			for k, _ := c.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix); k, _ = c.Next() {
				count++
			}
			if count >= MaxDevicesPerAccount {
				return ErrTooManyDevices
			}
		}
		return put(b, key, Device{RelayKey: relayKey, LastSeen: s.now().UTC()})
	})
}

// Device devuelve un dispositivo.
func (s *Store) Device(acct, dev string) (Device, bool, error) {
	var (
		device Device
		ok     bool
	)
	err := s.db.View(func(tx *bolt.Tx) error {
		var err error
		device, ok, err = get[Device](tx.Bucket(bucketDevices), deviceKey(acct, dev))
		return err
	})
	return device, ok, err
}

// Devices lista los dispositivos de una cuenta.
func (s *Store) Devices(acct string) ([]DeviceEntry, error) {
	var out []DeviceEntry
	err := s.db.View(func(tx *bolt.Tx) error {
		c := tx.Bucket(bucketDevices).Cursor()
		prefix := []byte(acct + "/")
		for k, v := c.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix); k, v = c.Next() {
			var device Device
			if err := json.Unmarshal(v, &device); err != nil {
				return err
			}
			out = append(out, DeviceEntry{ID: string(k[len(prefix):]), LastSeen: device.LastSeen})
		}
		return nil
	})
	return out, err
}

// RemoveDevice da de baja un dispositivo: borra su suscripción y su buzón.
func (s *Store) RemoveDevice(acct, dev string) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		if err := tx.Bucket(bucketDevices).Delete(deviceKey(acct, dev)); err != nil {
			return err
		}
		return deletePrefix(tx.Bucket(bucketMailbox), mailboxPrefix(acct, dev))
	})
}

func deletePrefix(b *bolt.Bucket, prefix []byte) error {
	var keys [][]byte
	c := b.Cursor()
	for k, _ := c.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix); k, _ = c.Next() {
		keys = append(keys, append([]byte(nil), k...))
	}
	for _, k := range keys {
		if err := b.Delete(k); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) updateDevice(acct, dev string, change func(*Device)) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketDevices)
		device, ok, err := get[Device](b, deviceKey(acct, dev))
		if err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		change(&device)
		return put(b, deviceKey(acct, dev), device)
	})
}

// SetWebPush guarda (reemplaza) la suscripción de push de un dispositivo.
func (s *Store) SetWebPush(acct, dev string, sub WebPush) error {
	return s.updateDevice(acct, dev, func(d *Device) { d.WebPush = &sub })
}

// ClearWebPush borra la suscripción (el servicio de push respondió 404 o 410), solo si sigue siendo la de endpoint.
func (s *Store) ClearWebPush(acct, dev, endpoint string) error {
	return s.updateDevice(acct, dev, func(d *Device) {
		if d.WebPush != nil && d.WebPush.Endpoint == endpoint {
			d.WebPush = nil
		}
	})
}

// Touch actualiza lastSeen.
func (s *Store) Touch(acct, dev string) error {
	return s.updateDevice(acct, dev, func(d *Device) { d.LastSeen = s.now().UTC() })
}

// PutMailbox guarda (reemplaza) el blob de una ranura. El tamaño lo acota el tope de marco del hub (128 KiB).
func (s *Store) PutMailbox(acct, dev, slot string, blob []byte) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		if tx.Bucket(bucketDevices).Get(deviceKey(acct, dev)) == nil {
			return ErrNotFound
		}
		b := tx.Bucket(bucketMailbox)
		prefix := mailboxPrefix(acct, dev)
		key := append(append([]byte(nil), prefix...), slot...)
		if b.Get(key) == nil {
			count := 0
			c := b.Cursor()
			for k, _ := c.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix); k, _ = c.Next() {
				count++
			}
			if count >= MaxMailboxSlots {
				return ErrMailboxFull
			}
		}
		return put(b, key, MailboxItem{Slot: slot, Blob: blob, At: s.now().UTC()})
	})
}

// Mailbox devuelve los blobs vigentes de un dispositivo.
func (s *Store) Mailbox(acct, dev string) ([]MailboxItem, error) {
	var out []MailboxItem
	cutoff := s.now().Add(-MailboxTTL)
	err := s.db.View(func(tx *bolt.Tx) error {
		c := tx.Bucket(bucketMailbox).Cursor()
		prefix := mailboxPrefix(acct, dev)
		for k, v := c.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix); k, v = c.Next() {
			var item MailboxItem
			if err := json.Unmarshal(v, &item); err != nil {
				return err
			}
			if item.At.After(cutoff) {
				out = append(out, item)
			}
		}
		return nil
	})
	return out, err
}

// SweepMailbox borra los blobs vencidos. Devuelve cuántos borró.
func (s *Store) SweepMailbox() (int, error) {
	cutoff := s.now().Add(-MailboxTTL)
	removed := 0
	err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucketMailbox)
		var expired [][]byte
		err := b.ForEach(func(k, v []byte) error {
			var item MailboxItem
			if err := json.Unmarshal(v, &item); err != nil || !item.At.After(cutoff) {
				expired = append(expired, append([]byte(nil), k...))
			}
			return nil
		})
		if err != nil {
			return err
		}
		for _, k := range expired {
			if err := b.Delete(k); err != nil {
				return err
			}
		}
		removed = len(expired)
		return nil
	})
	return removed, err
}

// MailboxBytes suma el tamaño de los blobs (para el resumen periódico).
func (s *Store) MailboxBytes() (int, error) {
	total := 0
	err := s.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket(bucketMailbox).ForEach(func(_, v []byte) error {
			total += len(v)
			return nil
		})
	})
	return total, err
}

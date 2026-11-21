// prbar-relay: el relay de PRBar entre la Mac y el iPhone (spec P). Ve solo texto cifrado e ids de ruteo.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"prbar-relay/internal/config"
	"prbar-relay/internal/hub"
	"prbar-relay/internal/logx"
	"prbar-relay/internal/store"
	"prbar-relay/internal/webpush"
)

func main() {
	log := logx.New(os.Stdout)
	if err := run(log); err != nil {
		log.Error("exit", "err", err.Error())
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	db, err := store.Open(filepath.Join(cfg.DataDir, "relay.db"), cfg.MaxAccounts, time.Now)
	if err != nil {
		return err
	}
	defer db.Close()

	// Sin VAPID el relay arranca igual, con los pushes apagados (GET /v1/vapid da 404).
	var pusher hub.Pusher
	if cfg.PushConfigured() {
		sender, err := webpush.New(webpush.Options{PrivateKey: cfg.VAPIDPrivateKey, Subject: cfg.VAPIDSubject,
			TestEndpointPrefix: cfg.WebPushTestEndpoint})
		if err != nil {
			log.Warn("push disabled", "reason", err.Error())
		} else {
			pusher = sender
		}
	} else {
		log.Warn("push disabled", "reason", "VAPID_PRIVATE_KEY missing")
	}

	h := hub.New(hub.Options{PublicHost: cfg.PublicHost, EnrollToken: cfg.EnrollToken, Store: db, Log: log,
		Pusher: pusher, TrustedProxies: cfg.TrustedProxies, WebPushTestEndpoint: cfg.WebPushTestEndpoint})
	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           h.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go maintain(ctx, h, db, log)

	errs := make(chan error, 1)
	go func() { errs <- server.ListenAndServe() }()
	log.Info("listening", "addr", cfg.Listen, "push", pusher != nil, "testMode", cfg.TestMode)
	select {
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return server.Shutdown(shutdown)
}

// maintain: ranuras vencidas cada 30 s, buzón vencido cada hora, resumen cada 10 min.
func maintain(ctx context.Context, h *hub.Hub, db *store.Store, log *slog.Logger) {
	slots := time.NewTicker(30 * time.Second)
	sweep := time.NewTicker(time.Hour)
	summary := time.NewTicker(10 * time.Minute)
	defer slots.Stop()
	defer sweep.Stop()
	defer summary.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-slots.C:
			h.Sweep()
		case <-sweep.C:
			if removed, err := db.SweepMailbox(); err != nil {
				log.Error("mailbox sweep", "err", err.Error())
			} else if removed > 0 {
				log.Info("mailbox sweep", "removed", removed)
			}
		case <-summary.C:
			h.Summary()
		}
	}
}

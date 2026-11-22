// prbar-relay: el relay de PRBar entre la Mac y el teléfono (spec P y W). Ve solo texto cifrado e ids de ruteo, y
// sirve la web app del teléfono.
//
//	prbar-relay                 el relay
//	prbar-relay -healthcheck    GET a su propio /healthz (el healthcheck de Docker: la imagen no tiene shell ni curl)
//	prbar-relay -check-config   valida el entorno como al arrancar, sin abrir la base (deploy.sh, antes de reiniciar)
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"prbar-relay/internal/config"
	"prbar-relay/internal/hub"
	"prbar-relay/internal/logx"
	"prbar-relay/internal/store"
	"prbar-relay/internal/web"
	"prbar-relay/internal/webpush"
)

func main() {
	healthcheck := flag.Bool("healthcheck", false, "check the running relay's /healthz and exit 0 (healthy) or 1")
	checkConfig := flag.Bool("check-config", false, "validate the environment and exit 0 (valid) or 1")
	flag.Parse()
	switch {
	case *healthcheck:
		if err := probeHealth(healthURL(os.Getenv("RELAY_LISTEN")), 2*time.Second); err != nil {
			fmt.Fprintln(os.Stderr, "unhealthy:", err)
			os.Exit(1)
		}
		return
	case *checkConfig:
		summary, err := checkEnv(os.Getenv)
		if err != nil {
			fmt.Fprintln(os.Stderr, "invalid configuration:", err)
			os.Exit(1)
		}
		fmt.Println(summary)
		return
	}
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

	// La web app del teléfono, embebida (spec W.7).
	app, err := web.New(cfg.PublicHost, cfg.ClearSiteData)
	if err != nil {
		return err
	}

	h := hub.New(hub.Options{PublicHost: cfg.PublicHost, EnrollToken: cfg.EnrollToken, Store: db, Log: log,
		Pusher: pusher, TrustedProxies: cfg.TrustedProxies, Web: app, WebPushTestEndpoint: cfg.WebPushTestEndpoint,
		AllowLocalOrigins: cfg.TestMode, AccountIdle: time.Duration(cfg.AccountIdleDays) * 24 * time.Hour})
	// Sin ReadTimeout ni WriteTimeout: valdrían también para los WebSocket, que duran horas. ReadHeaderTimeout e
	// IdleTimeout no los tocan (una vez aceptado, el WebSocket ya no es un pedido HTTP); el cuerpo de
	// POST /v1/accounts tiene su propio plazo.
	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           h.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	// Shutdown no espera los WebSocket (conexiones secuestradas): se cierran con 1001 para que reconecten enseguida.
	server.RegisterOnShutdown(h.Close)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go maintain(ctx, h, db, log)

	errs := make(chan error, 1)
	go func() { errs <- server.ListenAndServe() }()
	log.Info("listening", "addr", cfg.Listen, "push", pusher != nil, "testMode", cfg.TestMode,
		"clearSiteData", cfg.ClearSiteData)
	select {
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	// Todo dentro de los 10 s que da `docker stop` antes de matar el proceso.
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err = server.Shutdown(shutdown)
	drain, cancelDrain := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelDrain()
	if !h.Wait(drain) {
		log.Warn("shutdown", "reason", "connections still open")
	}
	return err
}

// healthURL: el /healthz del propio relay según RELAY_LISTEN (":8080" por defecto: se le pregunta a 127.0.0.1).
func healthURL(listen string) string {
	listen = strings.TrimSpace(listen)
	if listen == "" {
		listen = ":8080"
	}
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		host, port = "", "8080"
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/healthz"
}

func probeHealth(url string, timeout time.Duration) error {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// checkEnv valida el entorno igual que al arrancar, y además que la clave VAPID, si está, sea un escalar de P-256
// (al arrancar eso solo apaga los pushes; antes de un deploy tiene que frenar). Nunca imprime secretos.
func checkEnv(getenv func(string) string) (string, error) {
	cfg, err := config.Load(getenv)
	if err != nil {
		return "", err
	}
	push := "off (no VAPID_PRIVATE_KEY)"
	if cfg.PushConfigured() {
		if _, err := webpush.New(webpush.Options{PrivateKey: cfg.VAPIDPrivateKey, Subject: cfg.VAPIDSubject}); err != nil {
			return "", fmt.Errorf("VAPID: %w", err)
		}
		push = "on"
	}
	return fmt.Sprintf("configuration ok: host %s, push %s, max accounts %d, idle accounts deleted after %d days",
		cfg.PublicHost, push, cfg.MaxAccounts, cfg.AccountIdleDays), nil
}

// maintain: ranuras vencidas cada 30 s, buzón vencido y cuentas inactivas cada hora, resumen cada 10 min.
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
			h.SweepAccounts()
		case <-summary.C:
			h.Summary()
		}
	}
}

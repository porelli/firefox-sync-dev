// ffs-admin: a small admin service for firefox-sync, see docs/admin/README.md
//
//	ffs-admin serve        web UI, and the sign-up gate for the self-hosted accounts
//	ffs-admin fxa-init     installs the sign-up policy in the accounts database (one-shot)
//	ffs-admin healthcheck  for the container healthcheck (the image has no shell)
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	log.SetFlags(0)
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ffs-admin serve | fxa-init | healthcheck")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(ctx)
	case "fxa-init":
		err = fxaInit(ctx)
	case "healthcheck":
		err = healthcheck()
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		log.Fatalf("ffs-admin %s: %v", os.Args[1], err)
	}
}

func env(name, fallback string) string {
	if v, ok := os.LookupEnv(name); ok && v != "" {
		return v
	}
	return fallback
}

// envSwitch: a switch of .env that is off unless asked for: 1, true, yes or on (any case);
// empty, 0, false, no or off is off, anything else an error (ADMIN_INSECURE_COOKIE=false must
// never turn it on)
func envSwitch(name string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on":
		return true, nil
	case "", "0", "false", "no", "off":
		return false, nil
	}
	return false, fmt.Errorf("%s must be 1, true or yes to turn it on (empty, 0, false or no: off), not %q", name, os.Getenv(name))
}

// switchOn: envSwitch, off when not valid (serve refuses to start then)
func switchOn(name string) bool {
	on, _ := envSwitch(name)
	return on
}

func envInt(name string, fallback int) int {
	v, err := strconv.Atoi(env(name, strconv.Itoa(fallback)))
	if err != nil {
		log.Fatalf("%s must be a number", name)
	}
	return v
}

func healthcheck() error {
	client := http.Client{Timeout: 5 * time.Second}
	res, err := client.Get("http://127.0.0.1:" + listenPort(env("ADMIN_LISTEN", ":8080")) + "/healthz")
	if err != nil {
		return err
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", res.StatusCode)
	}
	return nil
}

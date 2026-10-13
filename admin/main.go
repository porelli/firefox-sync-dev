// ffs-admin: a small admin service for firefox-sync, see ADMIN.md
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

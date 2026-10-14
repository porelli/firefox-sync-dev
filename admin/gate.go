package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The sign-up gate: a reverse proxy for the accounts API (fxa-auth) that refuses
// account creations the sign-up policy does not allow, with an error the accounts
// pages can show. The trigger installed by fxa-init enforces the same policy in the
// database, the gate only makes the refusal readable.

// SignupRefusal: "" allowed, refusedPolicy or refusedFull
type SignupChecker interface {
	SignupRefusal(ctx context.Context, email string) (string, error)
}

// FxA error shown by the accounts pages for a refused sign-up
// (REQUEST_BLOCKED: "The request was blocked for security reasons")
const signupRefusedErrno = 125

const maxCreateBody = 64 << 10

var signupEmail = regexp.MustCompile(`^[^@\x00-\x20\x7f]+@[^@\x00-\x20\x7f]+$`)

// corsOrigin is the accounts web pages (FXA_CONTENT_URL): they call the API from
// another host name, without the header of the auth server they cannot read the error
// event, when set, records refused sign-ups in the activity log
// probe: the token of the public check (public.go), answered here and never passed on
func newGate(upstream *url.URL, corsOrigin string, checker SignupChecker, event func(kind, detail string), probe string) http.Handler {
	corsOrigin = strings.TrimSuffix(corsOrigin, "/")
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(upstream)
			// keep what the reverse proxy in front sent: the auth server picks the
			// client address at a fixed depth of X-Forwarded-For (CLIENT_ADDRESS_DEPTH),
			// adding this hop would shift it. Host is part of the Hawk signatures.
			r.Out.Host = r.In.Host
			for _, h := range []string{"X-Forwarded-For", "X-Forwarded-Proto", "X-Forwarded-Host", "X-Forwarded-Port", "Forwarded"} {
				if v, ok := r.In.Header[h]; ok {
					r.Out.Header[h] = v
				}
			}
			r.Out.Header.Del(probeHeader)
		},
	}
	// errors of the gate itself; proxied responses have the auth server's headers
	fxaError := func(w http.ResponseWriter, r *http.Request, code, errno int, short, message string) {
		// the same CORS headers as the auth server, the pages send credentials
		if origin := r.Header.Get("Origin"); origin != "" && origin == corsOrigin {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Expose-Headers", "WWW-Authenticate,Server-Authorization,Timestamp,Accept-Language")
		}
		w.Header().Add("Vary", "Origin")
		w.Header().Set("Timestamp", strconv.FormatInt(time.Now().Unix(), 10))
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(map[string]any{"code": code, "errno": errno, "error": short, "message": message})
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("gate: %s %s: %v", r.Method, r.URL.Path, err)
		fxaError(w, r, http.StatusBadGateway, 999, "Bad Gateway", "Unexpected error")
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && path.Clean("/"+r.URL.Path) == "/v1/account/create" {
			// the admin UI asking through the reverse proxy: does it come here?
			if probe != "" && equal(r.Header.Get(probeHeader), probe) {
				w.Header().Set(probeHeader, probe)
				w.WriteHeader(http.StatusNoContent)
				return
			}
			body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxCreateBody))
			if err != nil {
				fxaError(w, r, http.StatusRequestEntityTooLarge, 113, "Request Entity Too Large", "Request body too large")
				return
			}
			// anything that does not parse is left to the auth server (and the trigger)
			if email := createEmail(body); email != "" {
				ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
				refusal, err := checker.SignupRefusal(ctx, email)
				cancel()
				if err != nil {
					log.Printf("gate: checking the sign-up policy: %v", err)
					fxaError(w, r, http.StatusServiceUnavailable, 201, "Service Unavailable", "Service unavailable")
					return
				}
				if refusal != "" {
					message := "Sign-ups are restricted on this server"
					if refusal == refusedFull {
						message = "This server is full: it takes no new accounts"
					}
					log.Printf("gate: sign-up refused: %s", message)
					if event != nil {
						// from anybody, unchecked by FxA: into the event log and the
						// alerts only when it looks like an email
						detail := email
						if len(detail) > 255 || !signupEmail.MatchString(detail) {
							detail = "invalid email"
						}
						if refusal == refusedFull {
							detail += " (the server is full: FXA_MAX_ACCOUNTS)"
						}
						go event("sign-up refused", detail)
					}
					fxaError(w, r, http.StatusBadRequest, signupRefusedErrno, "Request blocked", message)
					return
				}
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			r.ContentLength = int64(len(body))
		}
		proxy.ServeHTTP(w, r)
	})
}

// createEmail reads the email as the auth server does: JSON.parse takes only the
// exact key, the last one when repeated, where encoding/json would also take
// "Email" or "EMAIL"
func createEmail(body []byte) string {
	var fields map[string]json.RawMessage
	if json.Unmarshal(body, &fields) != nil {
		return ""
	}
	var email string
	if json.Unmarshal(fields["email"], &email) != nil {
		return ""
	}
	return email
}

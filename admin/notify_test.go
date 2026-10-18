package main

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// receiver: a destination on 127.0.0.1 recording the requests; answer decides the
// status of each (200 without)
type receiver struct {
	srv    *httptest.Server
	answer func(n int, r *http.Request, body []byte) (int, string)

	mu   sync.Mutex
	reqs []receivedRequest
}

type receivedRequest struct {
	method, path, rawPath, query string
	header                       http.Header
	body                         []byte
}

func (r receivedRequest) json(t *testing.T) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(r.body, &m); err != nil {
		t.Fatalf("%s %s: not JSON: %q", r.method, r.path, r.body)
	}
	return m
}

func newReceiver(t *testing.T) *receiver {
	rc := &receiver{}
	rc.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		rc.mu.Lock()
		n := len(rc.reqs)
		rc.reqs = append(rc.reqs, receivedRequest{r.Method, r.URL.Path, r.URL.EscapedPath(), r.URL.RawQuery, r.Header.Clone(), body})
		answer := rc.answer
		rc.mu.Unlock()
		status, text := 200, "ok"
		if answer != nil {
			status, text = answer(n, r, body)
		}
		w.WriteHeader(status)
		io.WriteString(w, text)
	}))
	t.Cleanup(rc.srv.Close)
	return rc
}

func (rc *receiver) host() string { return strings.TrimPrefix(rc.srv.URL, "http://") }

func (rc *receiver) requests() []receivedRequest {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	return append([]receivedRequest(nil), rc.reqs...)
}

func fastNotify(t *testing.T) {
	timeout, backoff := notifyTimeout, notifyBackoff
	notifyTimeout, notifyBackoff = 300*time.Millisecond, 10*time.Millisecond
	t.Cleanup(func() { notifyTimeout, notifyBackoff = timeout, backoff })
}

func mustNotifier(t *testing.T, raw string) (Notifier, string) {
	t.Helper()
	n, name, err := parseDestination(raw)
	if err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	return n, name
}

func TestParseNotify(t *testing.T) {
	basic := "Basic " + base64.StdEncoding.EncodeToString([]byte("user:pass"))
	for _, c := range []struct {
		raw, name, endpoint string
		header              map[string]string
	}{
		{"slack://hooks.slack.com/services/T0/B0/XXXXSECRET", "slack://hooks.slack.com", "https://hooks.slack.com/services/T0/B0/XXXXSECRET", nil},
		{"discord://discord.com/api/webhooks/123/TOKENSECRET", "discord://discord.com", "https://discord.com/api/webhooks/123/TOKENSECRET", nil},
		// the query of the workflow kept as it is
		{"teams://prod-01.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=SIGSECRET",
			"teams://prod-01.westeurope.logic.azure.com:443",
			"https://prod-01.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=SIGSECRET", nil},
		{"ntfy://tk_SECRETTOKEN@ntfy.sh/alerts-topic", "ntfy://ntfy.sh", "https://ntfy.sh/", map[string]string{"Authorization": "Bearer tk_SECRETTOKEN"}},
		{"ntfy+http://user:pass@ntfy.lan:8080/sub/topic", "ntfy+http://ntfy.lan:8080", "http://ntfy.lan:8080/sub", map[string]string{"Authorization": basic}},
		{"gotify://gotify.example.com/AppTokenSECRET", "gotify://gotify.example.com", "https://gotify.example.com/message", map[string]string{"X-Gotify-Key": "AppTokenSECRET"}},
		{"gotify+http://lan/gotify/AppTokenSECRET", "gotify+http://lan", "http://lan/gotify/message", nil},
		{"telegram://123456:ABC-SECRET_x/-1001234", "telegram://api.telegram.org", "", nil},
		{"matrix://syt_SECRET@matrix.example.org/!room:example.org", "matrix://matrix.example.org", "", map[string]string{"Authorization": "Bearer syt_SECRET"}},
		{"webhook+http://ha.lan:8123/api/webhook/HOOKSECRET?a=1&@Authorization=Bearer%20HEADERSECRET", "webhook+http://ha.lan:8123",
			"http://ha.lan:8123/api/webhook/HOOKSECRET?a=1", map[string]string{"Authorization": "Bearer HEADERSECRET"}},
		{"WEBHOOK://user:pass@n8n.example.com/webhook/x", "webhook://n8n.example.com", "https://n8n.example.com/webhook/x", map[string]string{"Authorization": basic}},
	} {
		n, name := mustNotifier(t, c.raw)
		h := hookOf(n)
		if name != c.name || (c.endpoint != "" && h.endpoint != c.endpoint) {
			t.Errorf("%s: %q %q", c.raw, name, h.endpoint)
		}
		for k, v := range c.header {
			if got := h.header.Get(k); got != v {
				t.Errorf("%s: %s %q", c.raw, k, got)
			}
		}
		if strings.Contains(name, "SECRET") || strings.Contains(name, "topic") {
			t.Errorf("%s: a secret in the name %q", c.raw, name)
		}
	}
	// the room of an alias, after the # (a fragment) or encoded
	for _, raw := range []string{"matrix://tok@matrix.org/#alerts:matrix.org", "matrix://tok@matrix.org/%23alerts:matrix.org"} {
		n, _ := mustNotifier(t, raw)
		if room := n.(*matrixNotifier).room; room != "#alerts:matrix.org" {
			t.Errorf("%s: room %q", raw, room)
		}
	}
	if n, _ := mustNotifier(t, "telegram://123456:ABC-SECRET_x/@mychannel"); n.(*telegramNotifier).chat != "@mychannel" {
		t.Error("telegram channel")
	}
	// a list, commas or spaces, the same host twice
	targets, err := parseNotify(" ntfy://ntfy.sh/a,ntfy://ntfy.sh/b \n slack://hooks.slack.com/services/x ")
	if err != nil || len(targets) != 3 || targets[0].name != "ntfy://ntfy.sh" || targets[1].name != "ntfy://ntfy.sh (2)" || targets[2].name != "slack://hooks.slack.com" {
		t.Errorf("%v %+v", err, targets)
	}
	if targets, err := parseNotify(""); err != nil || len(targets) != 0 {
		t.Errorf("empty: %v %v", err, targets)
	}
}

func TestParseNotifyErrors(t *testing.T) {
	for _, c := range []struct{ raw, want, name string }{
		{"https://hooks.slack.com/services/SECRETPATH", `unknown kind "https"`, "https://hooks.slack.com"},
		{"nonsense-SECRET", "not a URL", "not scheme://..."},
		{"slack://hooks.slack.com", "no path", "slack://hooks.slack.com"},
		{"slack://user:SECRETPW@hooks.slack.com/x", "no user or password", "slack://hooks.slack.com"},
		{"discord://discord.com/x/SECRETX", "not a Discord webhook", "discord://discord.com"},
		{"ntfy://ntfy.sh/", "no topic", "ntfy://ntfy.sh"},
		{"ntfy://ntfy.sh/bad.topic", "no topic", "ntfy://ntfy.sh"},
		{"gotify://gotify.example.com", "no application token", "gotify://gotify.example.com"},
		{"telegram://SECRETTOKEN/123", "no bot token", "telegram://…"},
		{"telegram://123:SECRET/", "no chat id", "telegram://…"},
		{"telegram+http://123:SECRET/1", "no +http", "telegram+http://…"},
		{"matrix://matrix.org/!r:x", "no access token", "matrix://matrix.org"},
		{"matrix://SECRETTOK@matrix.org/", "no room", "matrix://matrix.org"},
		{"webhook://h.example/p?@Bad%20Header=SECRETV", "is not a header", "webhook://h.example"},
		{"webhook://SECRETUSER@h.example/p", "a user without a password", "webhook://h.example"},
		{"slack://hooks.slack.com:SECRETPORT/x", "not a valid URL", "slack://hooks.slack.com:secretport"},
		// a user or password with / ? # in it (percent-encode them)
		{"webhook://bot:SECRET#abcd@example.com/x", "an @ after the host", "webhook://…"},
		{"webhook://alice:SECR/et@example.com/hook", "an @ after the host", "webhook://…"},
		{"ntfy://user:SECR?ss@host/topic", "an @ after the host", "ntfy://…"},
	} {
		_, err := parseNotify("ntfy://ntfy.sh/ok," + c.raw)
		if err == nil {
			t.Errorf("%s: accepted", c.raw)
			continue
		}
		msg := err.Error()
		if !strings.HasPrefix(msg, "ADMIN_NOTIFY, destination 2 of 2 ("+c.name+"): ") || !strings.Contains(msg, c.want) {
			t.Errorf("%s: %q", c.raw, msg)
		}
		if strings.Contains(strings.ToUpper(strings.TrimPrefix(msg, "ADMIN_NOTIFY, destination 2 of 2 ("+c.name+")")), "SECRET") {
			t.Errorf("%s: the secret in %q", c.raw, msg)
		}
	}
}

// tricky: what an outsider can put in an alert (the email of a refused sign-up), with
// the markup of every destination
const tricky = "mallory <!channel> <@everyone> @here [click](https://evil.example) *bold* & <b>x</b>"

// shownTricky: tricky as the messages show it, no @, :// or host name left for a service to act on
var shownTricky = defang(tricky)

func trickyAlert() Alert {
	now := time.Date(2026, 10, 17, 10, 0, 0, 0, time.UTC)
	return newAlert([]pendingAlert{{kind: "sign-up refused", at: now, text: alertText(tricky)}, {kind: "health", at: now, text: "Sync server is down: refused"}},
		map[string]int{"sign-up refused": 3}, "https://admin.example.com/activity")
}

// longAlert: 200 lines of 250 characters, more than any destination takes
func longAlert() Alert {
	var events []pendingAlert
	for i := 0; i < 200; i++ {
		events = append(events, pendingAlert{kind: "admin", at: time.Now(), text: strings.Repeat("é", 250)})
	}
	return newAlert(events, nil, "")
}

func TestNewAlert(t *testing.T) {
	a := trickyAlert()
	if a.Kind != "several" || a.Severity != "warning" || a.Title != "firefox-sync: 5 events" || len(a.Events) != 2 || a.Dropped["sign-up refused"] != 3 {
		t.Errorf("%+v", a)
	}
	lines := a.lines()
	if len(lines) != 3 || lines[0] != "2026-10-17 10:00  sign-up refused: "+tricky || lines[2] != "3 more sign-up refused" {
		t.Errorf("%q", lines)
	}
	one := newAlert([]pendingAlert{{kind: "admin", at: time.Now(), text: "admin signed in (password)"}}, nil, "")
	if one.Kind != "admin" || one.Severity != "info" || one.Title != "firefox-sync: admin: admin signed in (password)" {
		t.Errorf("%+v", one)
	}
	if text := one.plainText(1000, utf16Len, true); !strings.HasSuffix(text, "Times in UTC. Details in the admin UI, Activity.") || !strings.HasPrefix(text, one.Title+"\n\n") {
		t.Errorf("%q", text)
	}
}

func TestSlack(t *testing.T) {
	rc := newReceiver(t)
	n, _ := mustNotifier(t, "slack+http://"+rc.host()+"/services/T0/B0/SECRET")
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	req := rc.requests()[0]
	text, _ := req.json(t)["text"].(string)
	if req.method != "POST" || req.path != "/services/T0/B0/SECRET" || req.header.Get("Content-Type") != "application/json" {
		t.Errorf("%+v", req)
	}
	// no mention, no link of the outsider: < > & escaped
	if !strings.HasPrefix(text, "*firefox-sync: 5 events*\n") || !strings.Contains(text, "mallory &lt;!channel&gt; &lt;@\u2060everyone&gt; @\u2060here [click](https:\u2060//evil.\u2060example)") || strings.Contains(text, "<!channel>") || strings.Contains(text, "@here") ||
		!strings.Contains(text, "&amp; &lt;b&gt;") || !strings.HasSuffix(text, "Times in UTC. <https://admin.example.com/activity|Open the admin UI>") {
		t.Errorf("%q", text)
	}
	n.Send(context.Background(), longAlert())
	text, _ = rc.requests()[1].json(t)["text"].(string)
	if utf16Len(text) > 40000 || !strings.Contains(text, "more lines in the admin UI, Activity") {
		t.Errorf("%d characters", utf16Len(text))
	}
}

func TestDiscord(t *testing.T) {
	rc := newReceiver(t)
	rc.answer = func(int, *http.Request, []byte) (int, string) { return 204, "" }
	n, _ := mustNotifier(t, "discord+http://"+rc.host()+"/api/webhooks/123/SECRET")
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	m := rc.requests()[0].json(t)
	content, _ := m["content"].(string)
	// no mentions at all, the markdown escaped
	if mentions, _ := m["allowed_mentions"].(map[string]any); mentions == nil || len(mentions["parse"].([]any)) != 0 {
		t.Errorf("mentions: %v", m["allowed_mentions"])
	}
	if !strings.Contains(content, `\[click\]\(https:`+"\u2060"+`//evil.`+"\u2060"+`example\) \*bold\*`) || !strings.Contains(content, `\<\@`+"\u2060"+`everyone\>`) ||
		!strings.HasPrefix(content, "**firefox-sync: 5 events**\n") || !strings.HasSuffix(content, "<https://admin.example.com/activity>") {
		t.Errorf("%q", content)
	}
	n.Send(context.Background(), longAlert())
	content, _ = rc.requests()[1].json(t)["content"].(string)
	if utf16Len(content) > 2000 || !strings.Contains(content, "more lines in the admin UI, Activity") {
		t.Errorf("%d characters: %q", utf16Len(content), content[len(content)-100:])
	}
}

func TestTeams(t *testing.T) {
	rc := newReceiver(t)
	rc.answer = func(int, *http.Request, []byte) (int, string) { return 202, "" }
	n, _ := mustNotifier(t, "teams+http://"+rc.host()+"/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sig=SECRET")
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	req := rc.requests()[0]
	if req.query != "api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sig=SECRET" {
		t.Errorf("query %q", req.query)
	}
	var payload struct {
		Type        string
		Attachments []struct {
			ContentType string
			Content     struct {
				Type    string
				Version string
				Body    []struct {
					Type    string
					Inlines []struct{ Type, Text, Color string }
				}
				Actions []struct{ Type, URL string }
			}
		}
	}
	if err := json.Unmarshal(req.body, &payload); err != nil || payload.Type != "message" || len(payload.Attachments) != 1 {
		t.Fatalf("%v %s", err, req.body)
	}
	card := payload.Attachments[0]
	if card.ContentType != "application/vnd.microsoft.card.adaptive" || card.Content.Type != "AdaptiveCard" || len(card.Content.Body) != 5 ||
		len(card.Content.Actions) != 1 || card.Content.Actions[0].URL != "https://admin.example.com/activity" {
		t.Fatalf("%s", req.body)
	}
	// TextRuns: no markdown, the text as it is
	title, first := card.Content.Body[0].Inlines[0], card.Content.Body[1].Inlines[0]
	if card.Content.Body[1].Type != "RichTextBlock" || first.Type != "TextRun" || first.Text != "2026-10-17 10:00  sign-up refused: "+shownTricky ||
		title.Text != "firefox-sync: 5 events" || title.Color != "Attention" {
		t.Errorf("%+v %+v", title, first)
	}
	n.Send(context.Background(), longAlert())
	if size := len(rc.requests()[1].body); size > 28000 {
		t.Errorf("%d bytes", size)
	}
}

func TestNtfy(t *testing.T) {
	rc := newReceiver(t)
	n, _ := mustNotifier(t, "ntfy+http://tk_SECRET@"+rc.host()+"/alerts-topic")
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	req := rc.requests()[0]
	m := req.json(t)
	if req.method != "POST" || req.path != "/" || req.header.Get("Authorization") != "Bearer tk_SECRET" {
		t.Errorf("%+v", req)
	}
	if m["topic"] != "alerts-topic" || m["title"] != "firefox-sync: 5 events" || m["priority"] != float64(4) || m["click"] != "https://admin.example.com/activity" ||
		!strings.Contains(m["message"].(string), shownTricky) || strings.Contains(m["message"].(string), "5 events") {
		t.Errorf("%v", m)
	}
	n.Send(context.Background(), longAlert())
	if m := rc.requests()[1].json(t); len(m["message"].(string)) > 4000 || m["priority"] != float64(3) || m["click"] != nil {
		t.Errorf("%d bytes, %v", len(m["message"].(string)), m["priority"])
	}
}

func TestGotify(t *testing.T) {
	rc := newReceiver(t)
	n, _ := mustNotifier(t, "gotify+http://"+rc.host()+"/gotify/AppSECRET")
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	req := rc.requests()[0]
	m := req.json(t)
	// the token in its header, not in the URL (no access log has it)
	if req.path != "/gotify/message" || req.query != "" || req.header.Get("X-Gotify-Key") != "AppSECRET" {
		t.Errorf("%+v", req)
	}
	extras, _ := m["extras"].(map[string]any)
	if m["title"] != "firefox-sync: 5 events" || m["priority"] != float64(8) || !strings.Contains(m["message"].(string), shownTricky) ||
		extras["client::display"].(map[string]any)["contentType"] != "text/plain" {
		t.Errorf("%v", m)
	}
}

func TestTelegram(t *testing.T) {
	rc := newReceiver(t)
	api := telegramAPI
	telegramAPI = rc.srv.URL
	t.Cleanup(func() { telegramAPI = api })
	n, name := mustNotifier(t, "telegram://123456:ABC-SECRET/-1001234")
	if name != "telegram://api.telegram.org" {
		t.Error(name)
	}
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	req := rc.requests()[0]
	m := req.json(t)
	// plain text: no parse_mode, nothing is markup
	if req.path != "/bot123456:ABC-SECRET/sendMessage" || m["chat_id"] != "-1001234" || m["parse_mode"] != nil ||
		!strings.HasPrefix(m["text"].(string), "firefox-sync: 5 events\n") || !strings.Contains(m["text"].(string), shownTricky) || strings.Contains(m["text"].(string), "@here") ||
		!strings.HasSuffix(m["text"].(string), "Details: https://admin.example.com/activity") {
		t.Errorf("%s %v", req.path, m)
	}
	n.Send(context.Background(), longAlert())
	if text := rc.requests()[1].json(t)["text"].(string); utf16Len(text) > 4096 || !strings.Contains(text, "more lines") {
		t.Errorf("%d characters", utf16Len(text))
	}
}

func TestMatrix(t *testing.T) {
	rc := newReceiver(t)
	rc.answer = func(n int, r *http.Request, _ []byte) (int, string) {
		if r.Method == "GET" {
			return 200, `{"room_id":"!abc:example.org","servers":["example.org"]}`
		}
		return 200, `{"event_id":"$x"}`
	}
	n, _ := mustNotifier(t, "matrix+http://syt_SECRET@"+rc.host()+"/#alerts:example.org")
	for i := 0; i < 2; i++ {
		if err := n.Send(context.Background(), trickyAlert()); err != nil {
			t.Fatal(err)
		}
	}
	reqs := rc.requests()
	// the alias resolved once
	if len(reqs) != 3 || reqs[0].method != "GET" || reqs[0].rawPath != "/_matrix/client/v3/directory/room/%23alerts:example.org" {
		t.Fatalf("%+v", reqs)
	}
	put := reqs[1]
	if put.method != "PUT" || !strings.HasPrefix(put.path, "/_matrix/client/v3/rooms/!abc:example.org/send/m.room.message/ffs-") ||
		put.header.Get("Authorization") != "Bearer syt_SECRET" || put.path == reqs[2].path {
		t.Errorf("%+v", put)
	}
	m := put.json(t)
	formatted := m["formatted_body"].(string)
	if m["msgtype"] != "m.notice" || m["format"] != "org.matrix.custom.html" || !strings.Contains(m["body"].(string), shownTricky) ||
		!strings.Contains(formatted, "mallory &lt;!channel&gt; &lt;@\u2060everyone&gt;") || m["m.mentions"] == nil || len(m["m.mentions"].(map[string]any)) != 0 || strings.Contains(formatted, "<b>x</b>") ||
		!strings.HasPrefix(formatted, "<b>firefox-sync: 5 events</b><br>") || !strings.Contains(formatted, `<a href="https://admin.example.com/activity">`) {
		t.Errorf("%v", m)
	}
}

func TestWebhook(t *testing.T) {
	rc := newReceiver(t)
	n, _ := mustNotifier(t, "webhook+http://"+rc.host()+"/hook/SECRET?a=1&@Authorization=Bearer%20HDRSECRET&@X-Extra=yes")
	if err := n.Send(context.Background(), trickyAlert()); err != nil {
		t.Fatal(err)
	}
	req := rc.requests()[0]
	if req.method != "POST" || req.path != "/hook/SECRET" || req.query != "a=1" || req.header.Get("Authorization") != "Bearer HDRSECRET" || req.header.Get("X-Extra") != "yes" ||
		!strings.HasPrefix(req.header.Get("User-Agent"), "firefox-sync-admin/") {
		t.Errorf("%+v", req)
	}
	var p webhookPayload
	if err := json.Unmarshal(req.body, &p); err != nil {
		t.Fatal(err)
	}
	if p.Source != "firefox-sync" || p.Kind != "several" || p.Severity != "warning" || p.Title != "firefox-sync: 5 events" || p.Link != "https://admin.example.com/activity" ||
		len(p.Events) != 2 || p.Events[0].Kind != "sign-up refused" || p.Events[0].Text != tricky || !p.Events[0].Time.Equal(time.Date(2026, 10, 17, 10, 0, 0, 0, time.UTC)) ||
		p.Dropped["sign-up refused"] != 3 || !strings.Contains(p.Text, "3 more sign-up refused") || !strings.Contains(p.Text, shownTricky) || strings.Contains(p.Text, "@here") {
		t.Errorf("%+v", p)
	}
	// the documented field names (ADMIN.md#alerts), dropped always an object
	n.Send(context.Background(), testAlert("admin (password)", ""))
	m := rc.requests()[1].json(t)
	for _, key := range []string{"source", "kind", "severity", "title", "text", "link", "events", "dropped"} {
		if _, ok := m[key]; !ok {
			t.Errorf("no %s: %v", key, m)
		}
	}
	if m["kind"] != "test" || !strings.HasSuffix(m["events"].([]any)[0].(map[string]any)["time"].(string), "Z") {
		t.Errorf("%v", m)
	}
}

func TestDeliverRetries(t *testing.T) {
	fastNotify(t)
	for _, c := range []struct {
		name     string
		statuses []int
		requests int
		ok       bool
	}{
		{"5xx then ok: once more", []int{503, 200}, 2, true},
		{"5xx twice: one retry only", []int{500, 502, 200}, 2, false},
		{"4xx: no retry", []int{400, 200}, 1, false},
		{"429: no retry", []int{429, 200}, 1, false},
	} {
		rc := newReceiver(t)
		rc.answer = func(n int, _ *http.Request, _ []byte) (int, string) { return c.statuses[n], "answer" }
		n, _ := mustNotifier(t, "webhook+http://"+rc.host()+"/x")
		err := deliver(context.Background(), n, trickyAlert())
		if got := len(rc.requests()); got != c.requests || (err == nil) != c.ok {
			t.Errorf("%s: %d requests, %v", c.name, got, err)
		}
		if err != nil && !strings.Contains(err.Error(), "HTTP ") {
			t.Errorf("%s: %v", c.name, err)
		}
	}
	// no answer within notifyTimeout: a retry, then the error
	rc := newReceiver(t)
	rc.answer = func(int, *http.Request, []byte) (int, string) { time.Sleep(time.Second); return 200, "" }
	n, _ := mustNotifier(t, "webhook+http://"+rc.host()+"/x")
	start := time.Now()
	err := deliver(context.Background(), n, trickyAlert())
	if err == nil || !strings.Contains(err.Error(), "deadline exceeded") || time.Since(start) > 2*time.Second {
		t.Errorf("timeout: %v after %s", err, time.Since(start))
	}
	if got := len(rc.requests()); got != 2 {
		t.Errorf("timeout: %d requests", got)
	}
}

// the errors of the destinations, and the logs: never the URL's secret parts
func TestNotifyErrorsHideSecrets(t *testing.T) {
	fastNotify(t)
	var logs bytes.Buffer
	before := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(before) })
	// an answer that repeats the request's path
	rc := newReceiver(t)
	rc.answer = func(_ int, r *http.Request, _ []byte) (int, string) { return 404, "no hook at " + r.URL.String() }
	api := telegramAPI
	t.Cleanup(func() { telegramAPI = api })
	closed := httptest.NewServer(http.NotFoundHandler())
	closed.Close()
	telegramAPI = closed.URL
	for _, raw := range []string{
		"webhook+http://" + rc.host() + "/hook/SECRETPATH?token=SECRETQUERY&@Authorization=SECRETHEADER",
		"slack+http://" + rc.host() + "/services/T0/B0/SECRETSLACK",
		"telegram://123456:SECRETBOT/42",
		"ntfy+http://tk_SECRETNTFY@" + strings.TrimPrefix(closed.URL, "http://") + "/topic",
		"matrix+http://SECRETMATRIX@" + rc.host() + "/!room:example.org",
	} {
		n, name := mustNotifier(t, raw)
		o := &notifyOutlet{name: name, n: n}
		o.add("health", "Sync server is down", time.Now())
		o.flush(context.Background(), "")
		st := o.Status()
		if st.Err == "" || strings.Contains(st.Err, "SECRET") || o.Waiting() != 1 {
			t.Errorf("%s: %q, %d waiting", name, st.Err, o.Waiting())
		}
	}
	if strings.Contains(logs.String(), "SECRET") || !strings.Contains(logs.String(), "alerts to webhook+http://127.0.0.1:") || !strings.Contains(logs.String(), "HTTP 404: no hook at …") {
		t.Errorf("logs: %s", logs.String())
	}
}

// the per-kind caps of the email, on each destination's own queue; one that fails
// keeps its alerts without holding up the email or the others
func TestNotifyQueues(t *testing.T) {
	fastNotify(t)
	ok, failing := newReceiver(t), newReceiver(t)
	failing.answer = func(int, *http.Request, []byte) (int, string) { return 500, "down" }
	okN, okName := mustNotifier(t, "webhook+http://"+ok.host()+"/ok")
	badN, badName := mustNotifier(t, "webhook+http://"+failing.host()+"/bad")
	al := &Alerter{to: "admin@example.com", notifiers: []*notifyOutlet{{name: okName, n: okN}, {name: badName, n: badN}}}
	app := &App{alerter: al}
	for i := 0; i < 2*maxAlertsPerKind; i++ {
		app.alert("sign-up refused", "mallory@example.org")
	}
	app.alert("health", "Sync server is down: refused")
	if lines := al.take(); len(lines) != maxAlertsPerKind+2 {
		t.Errorf("email: %d lines", len(lines))
	}
	for _, o := range al.notifiers {
		o.flush(context.Background(), "")
	}
	var p webhookPayload
	if err := json.Unmarshal(ok.requests()[0].body, &p); err != nil || len(p.Events) != maxAlertsPerKind+1 || p.Dropped["sign-up refused"] != maxAlertsPerKind ||
		p.Title != "firefox-sync: 41 events" || p.Events[maxAlertsPerKind].Kind != "health" {
		t.Errorf("%v %d events %v", err, len(p.Events), p.Dropped)
	}
	bad := al.notifiers[1]
	if st := bad.Status(); st.Err != "HTTP 500: down" || bad.Waiting() != maxAlertsPerKind+1 || bad.failures != 1 || len(failing.requests()) != 2 {
		t.Errorf("failing: %+v, %d waiting, %d failures", st, bad.Waiting(), bad.failures)
	}
	// back: what it missed, with the count of those left out
	failing.answer = nil
	bad.flush(context.Background(), "")
	reqs := failing.requests()
	if err := json.Unmarshal(reqs[len(reqs)-1].body, &p); err != nil || len(p.Events) != maxAlertsPerKind+1 || p.Dropped["sign-up refused"] != maxAlertsPerKind || bad.Status().Err != "" {
		t.Errorf("requeued: %v %d events %v", err, len(p.Events), p.Dropped)
	}
	// no email (ADMIN_NOTIFY alone): only the destinations' queues
	al = &Alerter{notifiers: []*notifyOutlet{{name: okName, n: okN}}}
	al.add("health", "x")
	if al.emails() || al.alertQueue.Waiting() != 0 || al.notifiers[0].Waiting() != 1 {
		t.Error("notifications only: queued for email")
	}
}

func TestNewAlerter(t *testing.T) {
	t.Setenv("ALERT_EMAIL", "admin@example.com")
	t.Setenv("SMTP_HOST", "")
	t.Setenv("ADMIN_OIDC_REDIRECT_URL", "https://admin.example.com/auth/callback")
	if newAlerter(nil) != nil {
		t.Error("an alerter without SMTP and notifiers")
	}
	targets, _ := parseNotify("ntfy://ntfy.sh/x")
	al := newAlerter(targets)
	if al == nil || al.emails() || len(al.notifiers) != 1 || al.link != "https://admin.example.com/activity" || al.interval != 10*time.Minute {
		t.Fatalf("%+v", al)
	}
	t.Setenv("SMTP_HOST", "smtp.example.com")
	if al := newAlerter(targets); !al.emails() || al.to != "admin@example.com" {
		t.Error("email and notifications")
	}
	for redirect, want := range map[string]string{"": "", "https://example.com/admin/auth/callback": "https://example.com/admin/activity", "not a url": "",
		"https://u:p@admin.example.com/auth/callback": ""} {
		t.Setenv("ADMIN_OIDC_REDIRECT_URL", redirect)
		if got := adminLink(); got != want {
			t.Errorf("%q: %q", redirect, got)
		}
	}
}

func notifyApp(t *testing.T, raw ...string) (*App, http.Handler, *http.Cookie, *session) {
	t.Helper()
	targets, err := parseNotify(strings.Join(raw, ","))
	if err != nil {
		t.Fatal(err)
	}
	app := testApp()
	app.sync = &SyncDB{db: sql.OpenDB(&fakeFxa{maxUsers: "5", nodes: [][]driver.Value{}})}
	app.alerter = newAlerter(targets)
	// the overview's Health card, with its Alerts: the Notifications row alone
	app.health = &Health{app: app, started: time.Now()}
	if app.alerter != nil {
		app.health.checks = []check{{name: notifyCheckName, run: app.alerter.notifyCheck}}
		app.health.checkAll(context.Background())
	}
	h := app.routes()
	c, s := passwordSession(t, app, h)
	return app, h, c, s
}

func notifyEvents(t *testing.T, o *notifyOutlet, want string) {
	t.Helper()
	for i := 0; i < 100; i++ {
		events, _ := o.takeBatch()
		for _, e := range events {
			if strings.Contains(e.kind+": "+e.text, want) {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("no event %q", want)
}

func TestTestNotification(t *testing.T) {
	fastNotify(t)
	t.Setenv("ALERT_EMAIL", "")
	rc := newReceiver(t)
	app, h, c, s := notifyApp(t, "webhook+http://"+rc.host()+"/hook/SECRET", "slack+http://"+rc.host()+"/services/SECRET")
	name := "webhook+http://" + rc.host()
	page := getPage(h, "/", c).Body.String()
	if !strings.Contains(page, `action="/alerts/test-notification"`) || !strings.Contains(page, "to the 2 destinations of <code>ADMIN_NOTIFY</code>") ||
		!strings.Contains(page, "Notifications to "+strings.ReplaceAll(name, "+", "&#43;")+": none sent since the start") || strings.Contains(page, "SECRET") ||
		strings.Contains(page, `action="/alerts/test"`) || strings.Contains(page, "No alerts:") {
		t.Errorf("overview: %s", page)
	}
	// the form's token, and the same site
	if w := post(h, "/alerts/test-notification", url.Values{}, c, nil); w.Code != http.StatusForbidden || len(rc.requests()) != 0 {
		t.Errorf("without the token: %d", w.Code)
	}
	w := post(h, "/alerts/test-notification", url.Values{"csrf": {s.csrf}}, c, nil)
	if w.Code != http.StatusSeeOther || s.message != "Sent a test notification to "+name+", slack+http://"+rc.host() || s.failed != "" {
		t.Fatalf("%d %q %q", w.Code, s.message, s.failed)
	}
	reqs := rc.requests()
	if len(reqs) != 2 {
		t.Fatalf("%d requests", len(reqs))
	}
	for _, r := range reqs {
		if r.path == "/hook/SECRET" && (r.json(t)["kind"] != "test" || !strings.Contains(r.json(t)["text"].(string), "sent by admin (password)")) {
			t.Errorf("%s", r.body)
		}
	}
	// apart from the alerts: the status of the destination unchanged
	if st := app.alerter.notifiers[0].Status(); !st.At.IsZero() {
		t.Error("the test changed the alerts' status")
	}
	// in the audit trail, and its alert
	notifyEvents(t, app.alerter.notifiers[0], "admin: Sent a test notification to "+name)
	// a refusal: in the flash and the audit trail, the answer without the secret
	rc.answer = func(_ int, r *http.Request, _ []byte) (int, string) { return 403, "forbidden " + r.URL.Path }
	post(h, "/alerts/test-notification", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.Contains(s.failed, name+": HTTP 403: forbidden") || strings.Contains(s.failed, "SECRET") || !strings.HasPrefix(s.message, "Tried a test notification") {
		t.Errorf("%q %q", s.message, s.failed)
	}
	notifyEvents(t, app.alerter.notifiers[0], "Tried a test notification to "+name)
	o := app.alerter.notifiers[0]
	if st := o.Status(); st.Err != "" || o.failures != 0 || o.testFailures != 1 {
		t.Errorf("a failed test counted with the alerts: %+v %d %d", st, o.failures, o.testFailures)
	}
	if !strings.Contains(prometheusText(t, app), `ffs_notify_test_failures_total{destination="`+name+`"} 1`) {
		t.Error("no ffs_notify_test_failures_total")
	}
	// without ADMIN_NOTIFY: no button, refused
	app.alerter = nil
	app.health.checks = []check{{name: "Sync server", health: func(context.Context) error { return nil }}}
	app.health.checkAll(context.Background())
	if page := getPage(h, "/", c).Body.String(); strings.Contains(page, "test-notification") || !strings.Contains(page, "No alerts:") {
		t.Error("button without ADMIN_NOTIFY")
	}
	post(h, "/alerts/test-notification", url.Values{"csrf": {s.csrf}}, c, nil)
	if !strings.Contains(s.failed, "set ADMIN_NOTIFY") {
		t.Errorf("%q", s.failed)
	}
}

func TestNotifyHealthAndMetrics(t *testing.T) {
	fastNotify(t)
	t.Setenv("ALERT_EMAIL", "")
	t.Setenv("SMTP_HOST", "")
	rc := newReceiver(t)
	app, _, _, _ := notifyApp(t, "slack+http://"+rc.host()+"/services/SECRET")
	name := "slack+http://" + rc.host()
	h := newHealth(app)
	var row *check
	for i := range h.checks {
		if h.checks[i].name == "Notifications" {
			row = &h.checks[i]
		}
	}
	if row == nil {
		t.Fatal("no Notifications row")
	}
	h.checks = []check{*row}
	h.checkAll(context.Background())
	if c := h.Components()[0]; !c.Up || c.Detail != name+", none sent since the start" {
		t.Errorf("%+v", c)
	}
	o := app.alerter.notifiers[0]
	o.record(&sendError{msg: "HTTP 404: no_service"})
	h.checkAll(context.Background())
	c := h.Components()[0]
	if c.Up || c.Error != name+": HTTP 404: no_service" {
		t.Errorf("%+v", c)
	}
	notifyEvents(t, o, "health: Notifications is down: "+name+": HTTP 404: no_service")
	if list := needsAttention(attentionInput{now: time.Now(), components: []Component{c}}); len(list) != 1 || !strings.HasPrefix(list[0].Text, "Notifications fail ("+name) || list[0].Href != "#notify-status" {
		t.Errorf("%+v", list)
	}
	text := prometheusText(t, app)
	for _, want := range []string{`ffs_notify_failures_total{destination="` + name + `"} 1`, `ffs_notify_send_failing{destination="` + name + `"} 1`,
		`ffs_notify_last_success_timestamp_seconds{destination="` + name + `"} 0`} {
		if !strings.Contains(text, want) {
			t.Errorf("no %s", want)
		}
	}
	// no email: no metrics of the alert emails
	if strings.Contains(text, "ffs_alert_send_failing") || strings.Contains(text, "SECRET") {
		t.Error(text)
	}
	o.record(nil)
	h.checkAll(context.Background())
	if c := h.Components()[0]; !c.Up || !strings.Contains(c.Detail, ", last sent ") {
		t.Errorf("%+v", c)
	}
}

// ADMIN_NOTIFY on the configuration page: scheme://host, never the URLs
func TestNotifyOnTheConfigPage(t *testing.T) {
	t.Setenv("ALERT_EMAIL", "")
	t.Setenv("SMTP_HOST", "")
	spec := "slack://hooks.slack.com/services/T0/B0/SECRETSLACK,ntfy://tk_SECRETNTFY@ntfy.sh/secret-topic,telegram://123:SECRETBOT/42"
	t.Setenv("ADMIN_NOTIFY", spec)
	targets, err := parseNotify(spec)
	if err != nil {
		t.Fatal(err)
	}
	page := configPage(t, false, func(app *App, _ *fakeFxa) { app.alerter = newAlerter(targets) })
	if row := configRowOf(page, "Notifications to"); !strings.HasPrefix(row, "slack://hooks.slack.com, ntfy://ntfy.sh, telegram://api.telegram.org ADMIN_NOTIFY shown without") {
		t.Errorf("%q", row)
	}
	if strings.Contains(page, "SECRET") || strings.Contains(page, "secret-topic") {
		t.Error("a secret of ADMIN_NOTIFY on the page")
	}
	// no SMTP server, no email: nothing to say about it without the accounts
	hints := page[strings.Index(page, `<section id="hints">`):strings.Index(page, `<nav class="chips"`)]
	if strings.Contains(hints, "SMTP") {
		t.Errorf("hints: %s", hints)
	}
	t.Setenv("ALERT_EMAIL", "admin@example.com")
	page = configPage(t, false, func(app *App, _ *fakeFxa) { app.alerter = newAlerter(targets) })
	if !strings.Contains(page, "no alert email is sent, the alerts go to ADMIN_NOTIFY only") {
		t.Error("ADMIN_ALERT_EMAIL without SMTP")
	}
	t.Setenv("ADMIN_NOTIFY", "")
	page = configPage(t, false, nil)
	if row := configRowOf(page, "Notifications to"); !strings.HasPrefix(row, "nowhere (default) ADMIN_NOTIFY") {
		t.Errorf("%q", row)
	}
}

// the accounts need an SMTP server whatever the alerts use; Sync alone does not
func TestSMTPOnlyForTheAccounts(t *testing.T) {
	if c := accountsSMTPCheck(nil); c.OK || !strings.Contains(c.Text, "nobody can sign up or sign in") || !strings.Contains(c.Text, "ADMIN_NOTIFY only replaces email for the admin UI's alerts") {
		t.Errorf("%+v", c)
	}
	if c := accountsSMTPCheck(&Mailer{host: "smtp.example.com", port: "587"}); !c.OK || !strings.Contains(c.Text, "smtp.example.com:587") {
		t.Errorf("%+v", c)
	}
	t.Setenv("SMTP_HOST", "")
	app := testApp()
	for _, c := range app.setupChecks(context.Background(), nil, nil) {
		if strings.Contains(c.Name, "SMTP") {
			t.Errorf("without the accounts: %+v", c)
		}
	}
}

// a user or password with / ? # in it: refused, never named after what follows it
func TestParseNotifyStrayAt(t *testing.T) {
	for raw, secret := range map[string]string{
		"webhook://bot:1234#abcd@example.com/x":     "1234",
		"webhook://alice:s3cr/et@example.com/hook":  "s3cr",
		"ntfy://user:pa?ss@host.example.com/topic":  "ss@",
		"matrix://tok/en@matrix.example.org/!r:x.y": "tok",
	} {
		_, err := parseNotify(raw)
		scheme, _, _ := strings.Cut(raw, "://")
		if err == nil || !strings.Contains(err.Error(), "("+scheme+"://…): an @ after the host: percent-encode / ? # in the user or password (%2F %3F %23)") ||
			strings.Contains(err.Error(), secret) {
			t.Errorf("%s: %v", raw, err)
		}
		if name := safeName(raw); name != scheme+"://…" {
			t.Errorf("%s: named %q", raw, name)
		}
	}
	// percent-encoded, and the headers of the webhook's query: fine
	for _, raw := range []string{"webhook://alice:s3cr%2Fet@example.com/hook", "webhook://example.com/x?a=1&@Authorization=Bearer%20t", "ntfy://user:pa%3Fss@host.example.com/topic"} {
		if _, name, err := parseDestination(raw); err != nil || strings.Contains(name, "@") {
			t.Errorf("%s: %q %v", raw, name, err)
		}
	}
	// the Basic auth header itself is a secret of the errors
	n, _ := mustNotifier(t, "webhook://alice:pw1234@example.com/hook")
	if got := hookOf(n).scrub("echo " + base64.StdEncoding.EncodeToString([]byte("alice:pw1234"))); strings.Contains(got, "YWxp") {
		t.Errorf("%q", got)
	}
}

func TestDefang(t *testing.T) {
	got := defang("x.@room.example https://phish.example/x@y")
	if strings.Contains(got, "@room") || strings.Contains(got, "://") || strings.Contains(got, "phish.example") ||
		strings.ReplaceAll(got, "⁠", "") != "x.@room.example https://phish.example/x@y" {
		t.Errorf("%q", got)
	}
}

// a retry posts the same Matrix event: the homeserver keeps one
func TestMatrixRetrySameTransaction(t *testing.T) {
	fastNotify(t)
	rc := newReceiver(t)
	rc.answer = func(n int, _ *http.Request, _ []byte) (int, string) {
		if n == 0 {
			return 502, "bad gateway"
		}
		return 200, `{"event_id":"$x"}`
	}
	n, _ := mustNotifier(t, "matrix+http://tok@"+rc.host()+"/!abc:example.org")
	if err := deliver(context.Background(), n, trickyAlert()); err != nil {
		t.Fatal(err)
	}
	if reqs := rc.requests(); len(reqs) != 2 || reqs[0].path != reqs[1].path {
		t.Errorf("%+v", reqs)
	}
}

// refused as it is (400, 413, 422): counted as lost, not sent again every round
func TestNotifyLostPayload(t *testing.T) {
	fastNotify(t)
	for _, c := range []struct {
		status  int
		lost    int64
		waiting int
	}{{413, 2, 0}, {422, 2, 0}, {400, 2, 0}, {401, 0, 2}, {404, 0, 2}} {
		rc := newReceiver(t)
		rc.answer = func(int, *http.Request, []byte) (int, string) { return c.status, "no" }
		n, name := mustNotifier(t, "webhook+http://"+rc.host()+"/x")
		o := &notifyOutlet{name: name, n: n}
		o.add("health", "a", time.Now())
		o.add("health", "b", time.Now())
		o.flush(context.Background(), "")
		if o.lost != c.lost || o.Waiting() != c.waiting || o.failures != 1 {
			t.Errorf("%d: %d lost, %d waiting", c.status, o.lost, o.Waiting())
		}
	}
	app := &App{alerter: &Alerter{notifiers: []*notifyOutlet{{name: "webhook://example.com", alertQueue: alertQueue{lost: 3}}}}}
	if !strings.Contains(prometheusText(t, app), `ffs_notify_alerts_lost_total{destination="webhook://example.com"} 3`) {
		t.Error("no ffs_notify_alerts_lost_total")
	}
}

// 200 short lines: the card stays under Teams' 28 KB with the JSON of each line
func TestTeamsManyShortLines(t *testing.T) {
	rc := newReceiver(t)
	var events []pendingAlert
	for i := 0; i < 200; i++ {
		events = append(events, pendingAlert{kind: "admin", at: time.Now(), text: "x"})
	}
	n, _ := mustNotifier(t, "teams+http://"+rc.host()+"/workflows/x")
	if err := n.Send(context.Background(), newAlert(events, map[string]int{"admin": 30}, "")); err != nil {
		t.Fatal(err)
	}
	if size := len(rc.requests()[0].body); size > 28000 {
		t.Errorf("%d bytes", size)
	}
}

// +http with a token to a host outside the local network: said at the start and on the
// configuration page
func TestNotifyInsecureHTTP(t *testing.T) {
	for raw, want := range map[string]bool{
		"webhook+http://example.com/x?@Authorization=Bearer%20t": true,
		"webhook+http://u:p@example.com/x":                       true,
		"ntfy+http://tk_x@ntfy.example.com/topic":                true,
		"slack+http://chat.example.com/hooks/x":                  true,
		"gotify+http://203.0.113.5/token":                        true,
		"webhook+http://example.com/x":                           false,
		"webhook+http://ha.lan:8123/x?@Authorization=Bearer%20t": false,
		"ntfy+http://tk_x@ntfy.local/topic":                      false,
		"slack+http://10.0.0.5/services/x":                       false,
		"gotify+http://gotify/token":                             false,
		"matrix+http://tok@127.0.0.1:8008/!r:x":                  false,
		"webhook://example.com/x?@Authorization=Bearer%20t":      false,
	} {
		targets, err := parseNotify(raw)
		if err != nil || targets[0].insecure != want {
			t.Errorf("%s: %v %v", raw, err, err == nil && targets[0].insecure)
		}
	}
	t.Setenv("ALERT_EMAIL", "")
	targets, _ := parseNotify("webhook+http://example.com/x?@Authorization=Bearer%20t")
	page := configPage(t, false, func(app *App, _ *fakeFxa) { app.alerter = newAlerter(targets) })
	if !strings.Contains(page, "ADMIN_NOTIFY sends webhook&#43;http://example.com its token over plain http (&#43;http) to a host outside the local network") {
		t.Error("no hint")
	}
}

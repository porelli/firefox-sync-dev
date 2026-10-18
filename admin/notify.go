package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

// Alerts to other destinations than email (ADMIN_NOTIFY): Slack, Discord, Microsoft
// Teams, ntfy, Gotify, Telegram, Matrix and any webhook. ADMIN_NOTIFY is a list of URLs,
// one per destination, separated by commas (or spaces), whose scheme says the kind:
// slack://hooks.slack.com/services/..., ntfy://ntfy.sh/topic... (ADMIN.md#alerts). Each
// destination gets the same alerts as the email, collected the same way
// (ALERT_INTERVAL_SECONDS, at most maxAlertsPerKind of each kind), each with its own queue:
// one that fails does not hold up the others, and gets what it missed once it works.
// The URLs hold tokens: only scheme://host is ever shown or logged (the destination's
// name), the errors of the destinations are scrubbed of the secret parts

// AlertEvent: one line of an alert
type AlertEvent struct {
	Time time.Time `json:"time"`
	Kind string    `json:"kind"`
	Text string    `json:"text"`
}

// Alert: what one notification says, the batch of a round (or the test)
type Alert struct {
	// the kind of every event, "several" when they differ, "test" for the test notification
	Kind string
	// warning when one of the events is of a kind that needs a look (warningKinds), info otherwise
	Severity string
	// one line: "firefox-sync: <the event>", or "firefox-sync: N events"
	Title  string
	Events []AlertEvent
	// the lines left out by the per-kind caps, by kind
	Dropped map[string]int
	// the Activity page of the admin UI, "" when its public URL is not known
	Link string
	// the same on every attempt: Matrix posts a transaction id once
	id string
}

// alertID: a new id for an alert
func alertID() string { return randomToken()[:16] }

// defang: text from outside (the email of a refused sign-up) that no service turns into
// a mention or a link: a word joiner (U+2060, invisible) after every @, in :// and after
// the dots of host names. events[].text of the webhook stays as it is
func defang(s string) string {
	return strings.NewReplacer("@", "@\u2060", "://", ":\u2060//", ".", ".\u2060").Replace(s)
}

// shown: the alert as the messages show it, its title and lines defanged
func (a Alert) shown() Alert {
	a.Title = defang(a.Title)
	events := make([]AlertEvent, len(a.Events))
	for i, e := range a.Events {
		e.Text = defang(e.Text)
		events[i] = e
	}
	a.Events = events
	return a
}

// warningKinds: the events that need a look (components down, backups, thresholds,
// security changes, blocks, bursts of sign-ups); the others are information
var warningKinds = map[string]bool{"health": true, "backup": true, "attention": true, "security": true, "blocked": true, "sign-up burst": true}

const (
	notifyAttempts = 2 // one retry
)

var (
	// each attempt, and the wait before the retry (the tests shorten them)
	notifyTimeout = 10 * time.Second
	notifyBackoff = 2 * time.Second
	// no redirects: a POST would become a GET elsewhere
	notifyClient = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
)

// Notifier sends an alert to one destination
type Notifier interface {
	Send(ctx context.Context, a Alert) error
}

// notifyOutlet: a destination with its queue of alerts
type notifyOutlet struct {
	name string // scheme://host, nothing secret
	n    Notifier
	// +http with a token to a host outside the local network (insecureHTTP)
	insecure bool
	alertQueue
	// test notifications that failed: apart, the Notifications row is the alerts'
	testFailures int64
}

// newAlert: the alert of a batch
func newAlert(events []pendingAlert, dropped map[string]int, link string) Alert {
	a := Alert{Severity: "info", Dropped: map[string]int{}, Link: link, id: alertID()}
	kinds := map[string]bool{}
	for _, e := range events {
		a.Events = append(a.Events, AlertEvent{Time: e.at, Kind: e.kind, Text: e.text})
		kinds[e.kind] = true
	}
	for kind, n := range dropped {
		a.Dropped[kind] = n
		kinds[kind] = true
	}
	for kind := range kinds {
		if warningKinds[kind] {
			a.Severity = "warning"
		}
		a.Kind = kind
	}
	if len(kinds) > 1 {
		a.Kind = "several"
	}
	if len(a.Events) == 1 && len(a.Dropped) == 0 {
		a.Title = alertText("firefox-sync: " + a.Events[0].Kind + ": " + a.Events[0].Text)
	} else {
		a.Title = fmt.Sprintf("firefox-sync: %d events", len(a.Events)+droppedCount(a.Dropped))
	}
	return a
}

func droppedCount(d map[string]int) int {
	n := 0
	for _, c := range d {
		n += c
	}
	return n
}

// testAlert: the test notification of the overview
func testAlert(who, link string) Alert {
	return Alert{Kind: "test", Severity: "info", Title: "firefox-sync: test notification", Link: link, Dropped: map[string]int{}, id: alertID(),
		Events: []AlertEvent{{Time: time.Now(), Kind: "test", Text: "A test notification of the admin UI of your firefox-sync server, sent by " + who + ". Alerts reach you this way."}}}
}

// lines: one per event (its time in the zone of the admin UI), then the counts of those left out
func (a Alert) lines() []string {
	lines := make([]string, 0, len(a.Events)+len(a.Dropped))
	for _, e := range a.Events {
		lines = append(lines, formatTime(e.Time, adminZone)+"  "+e.Kind+": "+e.Text)
	}
	kinds := make([]string, 0, len(a.Dropped))
	for kind := range a.Dropped {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	for _, kind := range kinds {
		lines = append(lines, fmt.Sprintf("%d more %s", a.Dropped[kind], kind))
	}
	return lines
}

// zoneNote: the last line, without the link
func (a Alert) zoneNote() string {
	if a.Link == "" {
		return "Times in " + adminZone.String() + ". Details in the admin UI, Activity."
	}
	return "Times in " + adminZone.String() + "."
}

func moreLines(n int) string {
	return fmt.Sprintf("... and %d more lines in the admin UI, Activity", n)
}

// utf16Len: the length as Slack, Discord, Telegram and Teams count it (or more)
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		if l := utf16.RuneLen(r); l > 0 {
			n += l
		} else {
			n++
		}
	}
	return n
}

func byteLen(s string) int { return len(s) }

// fitCount: how many of lines fit in budget, joined by sep: all, or the first n and a
// "more" line for the rest
func fitCount(budget int, size func(string) int, sep string, lines []string) int {
	joined := func(n int, more bool) int {
		total, parts := 0, n
		for _, l := range lines[:n] {
			total += size(l)
		}
		if more {
			total += size(moreLines(len(lines) - n))
			parts++
		}
		if parts > 1 {
			total += (parts - 1) * size(sep)
		}
		return total
	}
	if joined(len(lines), false) <= budget {
		return len(lines)
	}
	n := len(lines) - 1
	for n > 0 && joined(n, true) > budget {
		n--
	}
	return n
}

// withMore: the first n lines, and a "more" line for the rest
func withMore(lines []string, n int) []string {
	out := append([]string(nil), lines[:n]...)
	if n < len(lines) {
		out = append(out, moreLines(len(lines)-n))
	}
	return out
}

// compose: head, as many lines as fit and foot, within limit
func compose(limit int, size func(string) int, head string, lines []string, foot, sep string) string {
	budget := limit
	var parts []string
	if head != "" {
		budget -= size(head) + size(sep)
		parts = append(parts, head)
	}
	if foot != "" {
		budget -= size(foot) + size(sep)
	}
	parts = append(parts, withMore(lines, fitCount(budget, size, sep, lines))...)
	if foot != "" {
		parts = append(parts, foot)
	}
	return strings.Join(parts, sep)
}

// plainText: the alert as plain text, the title first (withTitle), the link last
func (a Alert) plainText(limit int, size func(string) int, withTitle bool) string {
	head := ""
	if withTitle {
		head = a.Title + "\n"
	}
	foot := "\n" + a.zoneNote()
	if a.Link != "" {
		foot += " Details: " + a.Link
	}
	return compose(limit, size, head, a.lines(), foot, "\n")
}

// sendError: what a destination answered, or why it could not be reached; retry: worth
// a second try (no answer, or a 5xx)
type sendError struct {
	msg    string
	retry  bool
	status int // the HTTP status of a refusal, 0 without one
}

// lostPayload: the destination refused what it was sent (bad request, too large,
// unprocessable): sending it again would fail again
func lostPayload(err error) bool {
	var se *sendError
	return errors.As(err, &se) && (se.status == http.StatusBadRequest || se.status == http.StatusRequestEntityTooLarge || se.status == http.StatusUnprocessableEntity)
}

func (e *sendError) Error() string { return e.msg }

// hook: what every destination does: a JSON request to its endpoint, its secrets kept
// out of the errors
type hook struct {
	endpoint string
	header   http.Header
	secrets  []string
}

// scrub: s without the secrets of the destination
func (h *hook) scrub(s string) string {
	for _, secret := range h.secrets {
		if len(secret) >= 4 {
			s = strings.ReplaceAll(s, secret, "…")
		}
	}
	return s
}

// addSecrets: these, and each of their parts of a URL path long enough to be a token
func (h *hook) addSecrets(values ...string) {
	for _, v := range values {
		if v == "" {
			continue
		}
		h.secrets = append(h.secrets, v)
		if u, err := url.PathUnescape(v); err == nil && u != v {
			h.secrets = append(h.secrets, u)
		}
		for _, part := range strings.FieldsFunc(v, func(r rune) bool { return r == '/' || r == '?' || r == '&' || r == '=' }) {
			if len(part) >= 6 {
				h.secrets = append(h.secrets, part)
			}
		}
	}
	// the longest first: a part never leaves the rest of a longer one
	sort.Slice(h.secrets, func(i, j int) bool { return len(h.secrets[i]) > len(h.secrets[j]) })
}

func (h *hook) do(ctx context.Context, method, endpoint string, body any) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return nil, &sendError{msg: "bad request: " + h.scrub(errText(err))}
	}
	for k, v := range h.header {
		req.Header[k] = v
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("User-Agent", "firefox-sync-admin/"+version)
	res, err := notifyClient.Do(req)
	if err != nil {
		return nil, &sendError{msg: h.scrub(errText(err)), retry: true}
	}
	defer res.Body.Close()
	answer, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	if res.StatusCode < 200 || res.StatusCode > 299 {
		msg := fmt.Sprintf("HTTP %d", res.StatusCode)
		if text := strings.TrimSpace(oneLine(string(answer), 200)); text != "" {
			msg += ": " + h.scrub(text)
		}
		return nil, &sendError{msg: msg, retry: res.StatusCode >= 500, status: res.StatusCode}
	}
	return answer, nil
}

// errText: the error without the URL net/http puts in front (Post "https://...": ...)
func errText(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	return err.Error()
}

// deliver: the alert to one destination, each attempt within notifyTimeout, once more
// after notifyBackoff when it did not answer or failed (5xx), never after a refusal (4xx)
func deliver(ctx context.Context, n Notifier, a Alert) error {
	var err error
	for attempt := 0; attempt < notifyAttempts; attempt++ {
		if attempt > 0 {
			var se *sendError
			if !errors.As(err, &se) || !se.retry {
				return err
			}
			select {
			case <-ctx.Done():
				return err
			case <-time.After(notifyBackoff):
			}
		}
		actx, cancel := context.WithTimeout(ctx, notifyTimeout)
		err = n.Send(actx, a)
		cancel()
		if err == nil {
			return nil
		}
	}
	return err
}

// flush sends what waits for the destination, put back when it fails
func (o *notifyOutlet) flush(ctx context.Context, link string) {
	events, dropped := o.takeBatch()
	if len(events) == 0 && len(dropped) == 0 {
		return
	}
	err := deliver(ctx, o.n, newAlert(events, dropped, link))
	o.record(err)
	switch {
	case err == nil:
	case lostPayload(err):
		// refused as it is: not again every round
		o.lose(len(events) + droppedCount(dropped))
		log.Printf("alerts to %s: %v: %d alerts dropped", o.name, err, len(events)+droppedCount(dropped))
	default:
		log.Printf("alerts to %s: %v", o.name, err)
		o.requeue()
	}
}

// ---- the destinations

// slack: an incoming webhook (also Mattermost's, which take the same JSON): mrkdwn
// text, < > & escaped so that nothing becomes a link or a mention
type slackNotifier struct{ hook }

func slackEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// linkTarget: a link as the markup of a destination takes it, nothing that ends it
func linkTarget(s string) string {
	return strings.NewReplacer("|", "%7C", ">", "%3E", "<", "%3C", " ", "%20", ")", "%29", "(", "%28", `"`, "%22").Replace(s)
}

func (n *slackNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	lines := a.lines()
	for i := range lines {
		lines[i] = slackEscape(lines[i])
	}
	foot := slackEscape(a.zoneNote())
	if a.Link != "" {
		foot += " <" + linkTarget(a.Link) + "|Open the admin UI>"
	}
	text := compose(39000, utf16Len, "*"+slackEscape(a.Title)+"*", lines, foot, "\n")
	_, err := n.do(ctx, http.MethodPost, n.endpoint, map[string]any{"text": text, "unfurl_links": false, "unfurl_media": false})
	return err
}

// discord: a channel webhook: markdown escaped, no mentions at all, at most 2000 characters
type discordNotifier struct{ hook }

var discordEscaper = strings.NewReplacer(`\`, `\\`, "*", `\*`, "_", `\_`, "~", `\~`, "`", "\\`", "|", `\|`, ">", `\>`, "<", `\<`,
	"[", `\[`, "]", `\]`, "(", `\(`, ")", `\)`, "#", `\#`, "@", `\@`)

func (n *discordNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	lines := a.lines()
	for i := range lines {
		lines[i] = discordEscaper.Replace(lines[i])
	}
	foot := discordEscaper.Replace(a.zoneNote())
	if a.Link != "" {
		// <...>: no preview
		foot += " <" + linkTarget(a.Link) + ">"
	}
	content := compose(2000, utf16Len, "**"+discordEscaper.Replace(a.Title)+"**", lines, foot, "\n")
	_, err := n.do(ctx, http.MethodPost, n.endpoint, map[string]any{"content": content, "allowed_mentions": map[string]any{"parse": []string{}}})
	return err
}

// teams: a workflow of Microsoft Teams ("When a Teams webhook request is received"):
// an Adaptive Card, its text in TextRuns, which take no markdown
type teamsNotifier struct{ hook }

func (n *teamsNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	run := func(text string, extra map[string]any) map[string]any {
		r := map[string]any{"type": "TextRun", "text": text}
		for k, v := range extra {
			r[k] = v
		}
		return map[string]any{"type": "RichTextBlock", "inlines": []any{r}}
	}
	color := "Default"
	if a.Severity == "warning" {
		color = "Attention"
	}
	body := []any{run(a.Title, map[string]any{"weight": "Bolder", "size": "Medium", "color": color})}
	// the card is at most 28 KB
	lines := a.lines()
	// each line a RichTextBlock: its JSON, about 90 bytes more than its text
	jsonSize := func(l string) int {
		b, _ := json.Marshal(l)
		return len(b) + 90
	}
	for _, l := range withMore(lines, fitCount(20000, jsonSize, "", lines)) {
		block := run(l, nil)
		block["spacing"] = "None"
		body = append(body, block)
	}
	body = append(body, run(a.zoneNote(), map[string]any{"isSubtle": true}))
	card := map[string]any{"type": "AdaptiveCard", "$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "version": "1.4",
		"body": body, "msteams": map[string]any{"width": "Full"}}
	if a.Link != "" {
		card["actions"] = []any{map[string]any{"type": "Action.OpenUrl", "title": "Open the admin UI", "url": a.Link}}
	}
	payload := map[string]any{"type": "message", "attachments": []any{map[string]any{
		"contentType": "application/vnd.microsoft.card.adaptive", "contentUrl": nil, "content": card}}}
	_, err := n.do(ctx, http.MethodPost, n.endpoint, payload)
	return err
}

// ntfy: a topic of an ntfy server, JSON published to its root (the topic in the body)
type ntfyNotifier struct {
	hook
	topic string
}

func (n *ntfyNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	msg := map[string]any{"topic": n.topic, "title": a.Title, "message": a.plainText(4000, byteLen, false), "priority": 3}
	if a.Severity == "warning" {
		msg["priority"], msg["tags"] = 4, []string{"warning"}
	}
	if a.Link != "" {
		msg["click"] = a.Link
	}
	_, err := n.do(ctx, http.MethodPost, n.endpoint, msg)
	return err
}

// gotify: an application of a Gotify server, its token in a header
type gotifyNotifier struct{ hook }

func (n *gotifyNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	priority := 4
	if a.Severity == "warning" {
		priority = 8
	}
	extras := map[string]any{"client::display": map[string]any{"contentType": "text/plain"}}
	if a.Link != "" {
		extras["client::notification"] = map[string]any{"click": map[string]any{"url": a.Link}}
	}
	_, err := n.do(ctx, http.MethodPost, n.endpoint, map[string]any{"title": a.Title, "message": a.plainText(30000, byteLen, false),
		"priority": priority, "extras": extras})
	return err
}

// telegram: a chat of a bot, plain text (no parse_mode: nothing is markup), at most 4096
type telegramNotifier struct {
	hook
	api, token, chat string
}

func (n *telegramNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	_, err := n.do(ctx, http.MethodPost, n.api+"/bot"+n.token+"/sendMessage", map[string]any{"chat_id": n.chat,
		"text": a.plainText(4096, utf16Len, true), "link_preview_options": map[string]any{"is_disabled": true}})
	return err
}

// matrix: a room, as the user of the access token (a bot), an m.notice with its HTML
type matrixNotifier struct {
	hook
	homeserver, room string

	mu     sync.Mutex
	roomID string // the room of an alias, once resolved
}

func (n *matrixNotifier) resolve(ctx context.Context) (string, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.roomID != "" {
		return n.roomID, nil
	}
	if strings.HasPrefix(n.room, "!") {
		n.roomID = n.room
		return n.roomID, nil
	}
	answer, err := n.do(ctx, http.MethodGet, n.homeserver+"/_matrix/client/v3/directory/room/"+url.PathEscape(n.room), nil)
	if err != nil {
		return "", fmt.Errorf("room %s: %w", n.room, err)
	}
	var dir struct {
		RoomID string `json:"room_id"`
	}
	if json.Unmarshal(answer, &dir) != nil || dir.RoomID == "" {
		return "", &sendError{msg: "room " + n.room + ": no room_id in the answer of the homeserver"}
	}
	n.roomID = dir.RoomID
	return n.roomID, nil
}

func (n *matrixNotifier) Send(ctx context.Context, a Alert) error {
	a = a.shown()
	room, err := n.resolve(ctx)
	if err != nil {
		return err
	}
	lines := a.lines()
	// an event is at most 64 KB, with both texts
	keep := fitCount(24000, func(s string) int { return len(html.EscapeString(s)) }, "<br>", lines)
	kept := withMore(lines, keep)
	plain := a.Title + "\n" + strings.Join(kept, "\n") + "\n" + a.zoneNote()
	escaped := make([]string, len(kept))
	for i, l := range kept {
		escaped[i] = html.EscapeString(l)
	}
	formatted := "<b>" + html.EscapeString(a.Title) + "</b><br>" + strings.Join(escaped, "<br>") + "<br><i>" + html.EscapeString(a.zoneNote()) + "</i>"
	if a.Link != "" {
		plain += " Details: " + a.Link
		formatted += ` <a href="` + html.EscapeString(a.Link) + `">Open the admin UI</a>`
	}
	// the transaction id of the alert, the same on the retry: the homeserver does not post it
	// twice. m.mentions empty: nobody pinged, not even by a name or @room in the body
	txn := "ffs-" + a.id
	if a.id == "" {
		txn = "ffs-" + alertID()
	}
	_, err = n.do(ctx, http.MethodPut, n.homeserver+"/_matrix/client/v3/rooms/"+url.PathEscape(room)+"/send/m.room.message/"+txn,
		map[string]any{"msgtype": "m.notice", "body": plain, "format": "org.matrix.custom.html", "formatted_body": formatted, "m.mentions": map[string]any{}})
	return err
}

// webhook: any other service: a POST of the alert as JSON (ADMIN.md#alerts has the schema)
type webhookNotifier struct{ hook }

type webhookPayload struct {
	Source   string         `json:"source"`
	Kind     string         `json:"kind"`
	Severity string         `json:"severity"`
	Title    string         `json:"title"`
	Text     string         `json:"text"`
	Link     string         `json:"link"`
	Events   []AlertEvent   `json:"events"`
	Dropped  map[string]int `json:"dropped"`
}

func (n *webhookNotifier) Send(ctx context.Context, a Alert) error {
	events := make([]AlertEvent, len(a.Events))
	for i, e := range a.Events {
		events[i] = AlertEvent{Time: e.Time.UTC().Truncate(time.Second), Kind: e.Kind, Text: e.Text}
	}
	dropped := a.Dropped
	if dropped == nil {
		dropped = map[string]int{}
	}
	// text: what Mattermost, Rocket.Chat and the like show (at most 16383 characters
	// there), defanged; the title and the events as they are
	_, err := n.do(ctx, http.MethodPost, n.endpoint, webhookPayload{Source: "firefox-sync", Kind: a.Kind, Severity: a.Severity, Title: a.Title,
		Text: a.shown().plainText(16000, utf16Len, true), Link: a.Link, Events: events, Dropped: dropped})
	return err
}

// ---- ADMIN_NOTIFY

// notifySchemes: the kinds of destination, as their URLs start
var notifySchemes = []string{"slack", "discord", "teams", "ntfy", "gotify", "telegram", "matrix", "webhook"}

var (
	ntfyTopic     = regexp.MustCompile(`^[-_A-Za-z0-9]{1,64}$`)
	telegramToken = regexp.MustCompile(`^[0-9]+:[-_A-Za-z0-9]+$`)
	telegramChat  = regexp.MustCompile(`^(-?[0-9]+|@[A-Za-z0-9_]{4,})$`)
	quoted        = regexp.MustCompile(`"[^"]*"`)
	schemeName    = regexp.MustCompile(`^[a-z][a-z0-9+]*$`)
	hostName      = regexp.MustCompile(`^[A-Za-z0-9.:\[\]-]+$`)
)

// telegramAPI: the Bot API (the tests use their own)
var telegramAPI = "https://api.telegram.org"

type notifyTarget struct {
	name     string
	n        Notifier
	insecure bool
}

// parseNotify reads ADMIN_NOTIFY: URLs separated by commas or spaces. An entry it cannot
// use stops the start, with its number and its scheme://host only
func parseNotify(spec string) ([]notifyTarget, error) {
	var targets []notifyTarget
	seen := map[string]int{}
	entries := strings.FieldsFunc(spec, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' || r == '\t' || r == '\r' })
	for i, raw := range entries {
		n, name, err := parseDestination(raw)
		if err != nil {
			return nil, fmt.Errorf("ADMIN_NOTIFY, destination %d of %d (%s): %v", i+1, len(entries), safeName(raw), err)
		}
		seen[name]++
		if seen[name] > 1 {
			name += " (" + strconv.Itoa(seen[name]) + ")"
		}
		targets = append(targets, notifyTarget{name: name, n: n, insecure: insecureHTTP(raw, n)})
	}
	return targets, nil
}

// strayAt: an @ after the host that is no header of the webhook's query (?@Name=, &@Name=):
// the end of a user or password with a / ? or # in it, the rest of which looks like the host
func strayAt(rest string) bool {
	i := strings.IndexAny(rest, "/?#")
	if i < 0 {
		return false
	}
	tail := rest[i:]
	for j := 0; j < len(tail); j++ {
		if tail[j] == '@' && (j == 0 || (tail[j-1] != '?' && tail[j-1] != '&')) {
			return true
		}
	}
	return false
}

// safeName: scheme://host of an entry that may not parse, never more
func safeName(raw string) string {
	scheme, rest, ok := strings.Cut(raw, "://")
	if !ok {
		return "not scheme://..."
	}
	scheme = strings.ToLower(scheme)
	if !schemeName.MatchString(scheme) {
		return "…"
	}
	if strings.HasPrefix(scheme, "telegram") {
		return scheme + "://…"
	}
	if strayAt(rest) {
		return scheme + "://…"
	}
	host, _, _ := strings.Cut(rest, "/")
	host, _, _ = strings.Cut(host, "?")
	host, _, _ = strings.Cut(host, "#")
	if i := strings.LastIndex(host, "@"); i >= 0 {
		host = host[i+1:]
	}
	if host == "" || !hostName.MatchString(host) {
		return scheme + "://…"
	}
	return scheme + "://" + strings.ToLower(host)
}

// parseDestination: the notifier of one URL and its name (scheme://host)
func parseDestination(raw string) (Notifier, string, error) {
	scheme, rest, ok := strings.Cut(raw, "://")
	if !ok {
		return nil, "", fmt.Errorf("not a URL: start with one of %s://", strings.Join(notifySchemes, "://, "))
	}
	scheme = strings.ToLower(scheme)
	kind, plainHTTP := strings.CutSuffix(scheme, "+http")
	kind = strings.TrimSuffix(kind, "+https")
	known := false
	for _, s := range notifySchemes {
		known = known || s == kind
	}
	if !known {
		return nil, "", fmt.Errorf("unknown kind %q: one of %s (webhook:// for any other service)", oneLine(kind, 20), strings.Join(notifySchemes, ", "))
	}
	if kind == "telegram" {
		if plainHTTP {
			return nil, "", errors.New("telegram:// goes to api.telegram.org over HTTPS, no +http")
		}
		token, chat, _ := strings.Cut(strings.TrimSuffix(rest, "/"), "/")
		if !telegramToken.MatchString(token) {
			return nil, "", errors.New("no bot token: telegram://<bot token>/<chat id>, the token as BotFather gives it (123456:ABC...)")
		}
		if !telegramChat.MatchString(chat) {
			return nil, "", errors.New("no chat id: telegram://<bot token>/<chat id>, a number (-100... for a group or a channel) or @channelname")
		}
		n := &telegramNotifier{api: telegramAPI, token: token, chat: chat}
		n.addSecrets(token)
		return n, "telegram://api.telegram.org", nil
	}
	if strayAt(rest) {
		return nil, "", errors.New("an @ after the host: percent-encode / ? # in the user or password (%2F %3F %23)")
	}
	base := "https://"
	if plainHTTP {
		base = "http://"
	}
	u, err := url.Parse(base + rest)
	if err != nil {
		// without the URL url.Parse quotes
		return nil, "", fmt.Errorf("not a valid URL: %s", quoted.ReplaceAllString(errText(err), "…"))
	}
	if u.Host == "" || u.Hostname() == "" {
		return nil, "", errors.New("no host")
	}
	name := scheme + "://" + strings.ToLower(u.Host)
	origin := base + u.Host
	segments := strings.FieldsFunc(u.Path, func(r rune) bool { return r == '/' })
	switch kind {
	case "slack", "discord", "teams":
		if u.User != nil {
			return nil, "", errors.New("no user or password here: the webhook URL as the service gives it, https:// replaced by " + kind + "://")
		}
		if len(segments) == 0 {
			return nil, "", errors.New("no path: the whole webhook URL, https:// replaced by " + kind + "://")
		}
		if kind == "discord" && (len(segments) < 4 || segments[0] != "api" || segments[1] != "webhooks") {
			return nil, "", errors.New("not a Discord webhook: discord://discord.com/api/webhooks/<id>/<token>")
		}
		h := hook{endpoint: base + rest}
		h.addSecrets(u.EscapedPath(), u.RawQuery, u.Path)
		switch kind {
		case "slack":
			return &slackNotifier{h}, name, nil
		case "discord":
			return &discordNotifier{h}, name, nil
		}
		return &teamsNotifier{h}, name, nil
	case "ntfy":
		if len(segments) == 0 || !ntfyTopic.MatchString(segments[len(segments)-1]) {
			return nil, "", errors.New("no topic: ntfy://[token@]host/<topic>, the topic of letters, digits, - and _")
		}
		n := &ntfyNotifier{topic: segments[len(segments)-1]}
		n.endpoint = origin + "/" + strings.Join(segments[:len(segments)-1], "/")
		n.header = http.Header{}
		n.addSecrets(n.topic)
		if err := userAuth(&n.hook, u, true); err != nil {
			return nil, "", err
		}
		return n, name, nil
	case "gotify":
		if len(segments) == 0 || u.User != nil {
			return nil, "", errors.New("no application token: gotify://host/<application token>")
		}
		token := segments[len(segments)-1]
		n := &gotifyNotifier{}
		n.endpoint = origin + strings.TrimSuffix("/"+strings.Join(segments[:len(segments)-1], "/"), "/") + "/message"
		n.header = http.Header{"X-Gotify-Key": {token}}
		n.addSecrets(token)
		return n, name, nil
	case "matrix":
		token := ""
		if u.User != nil {
			token = u.User.Username()
			if p, ok := u.User.Password(); ok {
				token = p
			}
		}
		if token == "" {
			return nil, "", errors.New("no access token: matrix://<access token>@homeserver/<room id or #alias:server>")
		}
		room := strings.TrimPrefix(u.Path, "/")
		if room == "" && u.Fragment != "" {
			room = "#" + u.Fragment
		}
		if !strings.HasPrefix(room, "!") && !strings.HasPrefix(room, "#") || !strings.Contains(room, ":") {
			return nil, "", errors.New("no room: matrix://<access token>@homeserver/<room id (!...:server) or #alias:server>")
		}
		n := &matrixNotifier{homeserver: origin, room: room}
		n.header = http.Header{"Authorization": {"Bearer " + token}}
		n.addSecrets(token)
		return n, name, nil
	}
	// webhook: the URL as is, without the user (Basic auth) and the @Header=value of the query
	n := &webhookNotifier{}
	n.header = http.Header{}
	var query []string
	for _, part := range strings.Split(u.RawQuery, "&") {
		key, value, _ := strings.Cut(part, "=")
		k, err1 := url.QueryUnescape(key)
		v, err2 := url.QueryUnescape(value)
		switch {
		case part == "":
		case err1 != nil || err2 != nil:
			return nil, "", errors.New("a part of the query is not URL-encoded")
		case strings.HasPrefix(k, "@"):
			if len(k) < 2 || strings.ContainsAny(k, " :\r\n") || strings.ContainsAny(v, "\r\n") {
				return nil, "", errors.New("a header of the query (@Name=value) is not a header")
			}
			n.header.Add(k[1:], v)
			n.addSecrets(v)
		default:
			query = append(query, part)
		}
	}
	if err := userAuth(&n.hook, u, false); err != nil {
		return nil, "", err
	}
	n.endpoint = origin + u.EscapedPath()
	if len(query) > 0 {
		n.endpoint += "?" + strings.Join(query, "&")
	}
	n.addSecrets(u.EscapedPath(), strings.Join(query, "&"))
	return n, name, nil
}

// insecureHTTP: a +http destination that sends a token (in a header, or the path of a
// Slack, Discord or Teams webhook) in clear to a host that is not on the local network
func insecureHTTP(raw string, n Notifier) bool {
	scheme, rest, _ := strings.Cut(raw, "://")
	kind, plain := strings.CutSuffix(strings.ToLower(scheme), "+http")
	if !plain {
		return false
	}
	h := hookOf(n)
	if h == nil || (len(h.header) == 0 && kind != "slack" && kind != "discord" && kind != "teams") {
		return false
	}
	u, err := url.Parse("http://" + rest)
	return err == nil && !localHost(u.Hostname())
}

// localHost: loopback, a private address, or a name of the local network (one label,
// .lan, .local, .internal, .home.arpa)
func localHost(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
	}
	if host == "localhost" || !strings.Contains(host, ".") {
		return true
	}
	for _, suffix := range []string{".lan", ".local", ".internal", ".home.arpa", ".localhost"} {
		if strings.HasSuffix(host, suffix) {
			return true
		}
	}
	return false
}

// hookOf: the request part of a notifier
func hookOf(n Notifier) *hook {
	switch n := n.(type) {
	case *slackNotifier:
		return &n.hook
	case *discordNotifier:
		return &n.hook
	case *teamsNotifier:
		return &n.hook
	case *ntfyNotifier:
		return &n.hook
	case *gotifyNotifier:
		return &n.hook
	case *telegramNotifier:
		return &n.hook
	case *matrixNotifier:
		return &n.hook
	case *webhookNotifier:
		return &n.hook
	}
	return nil
}

// InsecureNames: the destinations of insecureHTTP
func (al *Alerter) InsecureNames() []string {
	if al == nil {
		return nil
	}
	var names []string
	for _, o := range al.notifiers {
		if o.insecure {
			names = append(names, o.name)
		}
	}
	return names
}

// userAuth: user:password of the URL as Basic auth; a user alone as a bearer token (bearer)
func userAuth(h *hook, u *url.URL, bearer bool) error {
	if u.User == nil {
		return nil
	}
	user := u.User.Username()
	pass, hasPass := u.User.Password()
	switch {
	case hasPass:
		basic := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass))
		h.header.Set("Authorization", "Basic "+basic)
		h.addSecrets(pass, basic)
	case bearer && user != "":
		h.header.Set("Authorization", "Bearer "+user)
		h.addSecrets(user)
	case user != "":
		return errors.New("a user without a password: user:password@ for Basic auth, or a header with ?@Authorization=...")
	}
	return nil
}

// adminLink: the Activity page of the admin UI, from the public callback of its single
// sign-on (ADMIN_OIDC_REDIRECT_URL, https://admin.example.com/auth/callback); "" without
func adminLink() string {
	redirect := env("ADMIN_OIDC_REDIRECT_URL", "")
	u, err := url.Parse(redirect)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil {
		return ""
	}
	return u.Scheme + "://" + u.Host + strings.TrimSuffix(strings.TrimSuffix(u.Path, "/auth/callback"), "/") + "/activity"
}

// ---- the overview, the health row, the test

// NotifyStatus: a destination and its last send, for the overview and Prometheus
type NotifyStatus struct {
	Name     string
	Status   SendStatus
	Waiting  int
	Failures int64
	// alerts refused as they were, and failed test notifications
	Lost, TestFailures int64
}

func (al *Alerter) NotifyStatuses() []NotifyStatus {
	if al == nil {
		return nil
	}
	out := make([]NotifyStatus, 0, len(al.notifiers))
	for _, o := range al.notifiers {
		st := o.Status()
		o.mu.Lock()
		failures, lost, tests := o.failures, o.lost, o.testFailures
		o.mu.Unlock()
		out = append(out, NotifyStatus{Name: o.name, Status: st, Waiting: o.Waiting(), Failures: failures, Lost: lost, TestFailures: tests})
	}
	return out
}

// NotifyNames: the destinations, scheme://host
func (al *Alerter) NotifyNames() []string {
	if al == nil {
		return nil
	}
	names := make([]string, len(al.notifiers))
	for i, o := range al.notifiers {
		names[i] = o.name
	}
	return names
}

const notifyCheckName = "Notifications"

// notifyCheck: the Notifications row of the health table, from the last sends (nothing
// is sent for it): down while the last alert to a destination failed
func (al *Alerter) notifyCheck(context.Context) (string, error) {
	var failing []string
	var last time.Time
	for _, st := range al.NotifyStatuses() {
		if st.Status.Err != "" {
			failing = append(failing, st.Name+": "+st.Status.Err)
		}
		if st.Status.LastOK.After(last) {
			last = st.Status.LastOK
		}
	}
	if len(failing) > 0 {
		return "", errors.New(strings.Join(failing, "; "))
	}
	detail := strings.Join(al.NotifyNames(), ", ")
	if last.IsZero() {
		return detail + ", none sent since the start", nil
	}
	return detail + ", last sent " + formatTime(last, adminZone), nil
}

// testNotify sends a test notification to every destination of ADMIN_NOTIFY, right away
func (a *App) testNotify(w http.ResponseWriter, r *http.Request, s *session) {
	if a.alerter == nil || len(a.alerter.notifiers) == 0 {
		a.done(w, r, s, "", errors.New("no destination for a test notification: set ADMIN_NOTIFY"))
		return
	}
	alert := testAlert(auditWho(s), a.alerter.link)
	errs := make([]error, len(a.alerter.notifiers))
	var wg sync.WaitGroup
	for i, o := range a.alerter.notifiers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// apart from the alerts' status: a test does not change the Notifications row
			if errs[i] = deliver(r.Context(), o.n, alert); errs[i] != nil {
				o.mu.Lock()
				o.testFailures++
				o.mu.Unlock()
			}
		}()
	}
	wg.Wait()
	names := strings.Join(a.alerter.NotifyNames(), ", ")
	var failed []string
	for i, err := range errs {
		if err != nil {
			failed = append(failed, a.alerter.notifiers[i].name+": "+err.Error())
		}
	}
	if len(failed) > 0 {
		// tried: in the audit trail too, with the destinations' answers
		a.done(w, r, s, "Tried a test notification to "+names, &partialError{fmt.Errorf("the test notification was not sent to %s", strings.Join(failed, "; "))})
		return
	}
	a.done(w, r, s, "Sent a test notification to "+names, nil)
}

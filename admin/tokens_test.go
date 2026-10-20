package main

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

var (
	lineVerified = tokenVerified + ":1|ms|#token_type:OAuth\n"
	lineIssued   = tokenIssued + ":0|ms\n"
	lineGet      = "syncstorage.request.get_collections:1|c|#tokenserver_origin:rust\n"
	lineTs       = "syncstorage.tokenserver.storage.get_users:0|ms\n"
)

// tokenTest: a recorder on a clock of its own, what it writes in a tally
type tokenTest struct {
	r     *Recorder
	now   time.Time
	tally *errorTally
}

func newTokenTest() *tokenTest {
	tt := &tokenTest{now: time.Unix(1_800_000_000/60*60, 0), tally: newErrorTally()}
	tt.r = &Recorder{current: map[string]*metric{}, cumulative: map[string]*metric{}}
	tt.r.clock = func() time.Time { return tt.now }
	return tt
}

// send: a datagram of a sender d after the last one, written right away (a flush);
// the tokens refused then
func (tt *tokenTest) send(d time.Duration, sender, packet string) int64 {
	tt.now = tt.now.Add(d)
	tt.r.receive(sender, packet)
	minute, current, refusedAt := tt.r.drain()
	for name, m := range current {
		tt.tally.add(minute, name, m.count)
	}
	for at, n := range refusedAt {
		tt.tally.add(at, tokensRefusedMetric, n)
	}
	n, _, _ := tt.tally.refused()
	return n
}

func (tt *tokenTest) minute() int64 { return tt.now.Unix() / 60 * 60000 }

// TestTokensRefusedOfSplitDatagrams: the captured datagrams, each a minute after the
// one before, from the two buffers of syncstorage-rs. The verifications at the end of
// a datagram get their token in the next one: the four refused, never more on the way
func TestTokensRefusedOfSplitDatagrams(t *testing.T) {
	packets := capturedPackets(t)
	// what each datagram verified and did not issue, as if refused there
	perDatagram := int64(0)
	for _, p := range packets {
		r := &Recorder{current: map[string]*metric{}, cumulative: map[string]*metric{}}
		r.parseStatsd(p)
		if v := r.current[tokenVerified]; v != nil {
			n := v.count
			if c := r.current[tokenIssued]; c != nil {
				n -= c.count
			}
			perDatagram += max(n, 0)
		}
	}
	if perDatagram <= 4 {
		t.Errorf("%d verified and not issued per datagram: no split to test", perDatagram)
	}
	tt := newTokenTest()
	var after []int64
	for _, p := range packets {
		sender := "sync:1"
		if !strings.Contains(strings.ReplaceAll(p, "syncstorage.tokenserver.", ""), "syncstorage.") {
			sender = "sync:2"
		}
		n := tt.send(time.Minute, sender, p)
		if n > 4 || (len(after) > 0 && n < after[len(after)-1]) {
			t.Errorf("after each datagram: %v %d", after, n)
		}
		after = append(after, n)
	}
	if n, _, per := tt.tally.refused(); n != 4 {
		t.Errorf("%d refused: %v", n, per)
	}
	// the same minutes without the recorder's count (an admin UI from before it): the
	// guess of verified minus issued, once something newer came in
	legacy := newErrorTally()
	for m, n := range tt.tally.verified {
		legacy.add(m, tokenVerified, n)
	}
	for m, n := range tt.tally.issued {
		legacy.add(m, tokenIssued, n)
	}
	legacy.add(tt.minute()+60000, "syncstorage.request.get_collections", 1)
	if n, _, per := legacy.refused(); n != 4 {
		t.Errorf("before the recorder's count: %d refused: %v", n, per)
	}
}

// TestTokensRefusedNoneRefused: sign-ins only, every one with its token, the datagrams
// cut between a verification and its token. The guess of the minutes alone counted one
// refused, then none again (test_errors_by_kind saw no new one): the recorder none
func TestTokensRefusedNoneRefused(t *testing.T) {
	v, c := lineVerified, lineIssued
	tt := newTokenTest()
	for i, p := range []string{
		v + c + v + c + v,     // its last token in the next one
		c + v + c + v,         // the token of the one before, ends on a verification
		c + v + c + v + c + v, // and so on
		c + v + c + c,
		lineGet, // a minute later
	} {
		d := 2 * time.Second
		if i == 4 {
			d = time.Minute
		}
		tt.send(0, "sync:2", lineTs) // the tokenserver's buffer, another socket
		if n := tt.send(d, "sync:1", p); n != 0 {
			t.Errorf("after datagram %d: %d refused", i+1, n)
		}
	}
	// what the minutes alone said after the second one
	legacy := newErrorTally()
	legacy.add(60000, tokenVerified, 3)
	legacy.add(60000, tokenIssued, 2)
	legacy.add(120000, tokenVerified, 2)
	legacy.add(120000, tokenIssued, 2)
	legacy.add(180000, "syncstorage.tokenserver.storage.get_users", 2)
	if n, _, _ := legacy.refused(); n != 1 {
		t.Errorf("the minutes alone: %d refused", n)
	}
}

// TestTokensRefusedSlowToken: a token that comes after several datagrams of other
// requests (a wait for a database connection), within tokenWait: not refused
func TestTokensRefusedSlowToken(t *testing.T) {
	tt := newTokenTest()
	tt.send(0, "sync:1", lineVerified)
	for i := 0; i < 5; i++ {
		if n := tt.send(6*time.Second, "sync:1", strings.Repeat(lineGet, 8)); n != 0 {
			t.Fatalf("datagram %d before the token: %d refused", i+1, n)
		}
	}
	tt.send(5*time.Second, "sync:1", lineIssued+lineGet)
	if n := tt.send(time.Minute, "sync:1", lineGet); n != 0 {
		t.Errorf("%d refused", n)
	}
}

// TestTokensRefusedBusy: one refused among sign-ins every 2 s: counted once, in the
// minute of its verification, while the sign-ins go on. Paired with the oldest it would
// never be counted: each token would pay off the verification before its own
func TestTokensRefusedBusy(t *testing.T) {
	tt := newTokenTest()
	var minute int64
	for i := 0; i < 90; i++ {
		p := lineVerified + lineGet + lineIssued
		if i == 5 {
			p = lineVerified + lineGet
		}
		tt.send(2*time.Second, "sync:1", p)
		if i == 5 {
			minute = tt.minute()
		}
	}
	n, last, per := tt.tally.refused()
	if n != 1 || per[minute] != 1 || !last.Equal(time.UnixMilli(minute)) {
		t.Errorf("%d refused %v, its verification in %d", n, per, minute)
	}
}

// TestTokensRefusedSlowAndRefused: a slow token and refused ones next to it: as many
// refused as verifications without a token
func TestTokensRefusedSlowAndRefused(t *testing.T) {
	for refused := 1; refused <= 2; refused++ {
		tt := newTokenTest()
		tt.send(0, "sync:1", lineVerified) // its token comes late
		for i := 0; i < refused; i++ {
			tt.send(time.Second, "sync:1", lineVerified+lineGet)
		}
		for i := 0; i < 4; i++ {
			tt.send(5*time.Second, "sync:1", strings.Repeat(lineGet, 8))
		}
		tt.send(5*time.Second, "sync:1", lineIssued)
		if n := tt.send(time.Minute, "sync:1", lineGet); n != int64(refused) {
			t.Errorf("%d refused and a slow token: %d refused", refused, n)
		}
	}
}

// TestTokensRefusedSenders: each sender on its own: the tokenserver's buffer (another
// socket) does not settle the Sync server's, a second Sync server's token does not pay
// off the first one's verification. Refused in the minute its verification was
// written in, an earlier one
func TestTokensRefusedSenders(t *testing.T) {
	tt := newTokenTest()
	tt.send(0, "sync:1", lineVerified+lineGet)
	minute := tt.minute()
	tt.send(time.Second, "other:1", lineIssued)
	for i := 0; i < 5; i++ {
		if n := tt.send(20*time.Second, "sync:2", lineTs); n != 0 {
			t.Fatalf("only the tokenserver's datagrams: %d refused", n)
		}
	}
	if n := tt.send(time.Second, "sync:1", lineGet); n != 1 {
		t.Errorf("%d refused", n)
	}
	if _, _, per := tt.tally.refused(); per[minute] != 1 || minute == tt.minute() {
		t.Errorf("%v, its verification in %d", per, minute)
	}
}

// TestTokensRefusedBounds: what a sender leaves open, and the senders followed, are
// bounded; a quiet sender is dropped (what it had open not counted); a line of the
// recorder's name from a sender is not taken, nor in the statsd totals
func TestTokensRefusedBounds(t *testing.T) {
	tt := newTokenTest()
	if n := tt.send(0, "sync:1", strings.Repeat(lineVerified, maxOpenTokens+3)); n != 3 {
		t.Errorf("over the bound: %d refused", n)
	}
	if got := len(tt.r.tokens["sync:1"].open); got != maxOpenTokens {
		t.Errorf("%d open", got)
	}
	for i := 0; i < maxTokenSenders+4; i++ {
		tt.send(time.Second, fmt.Sprintf("sync:%d", 100+i), lineVerified)
	}
	if len(tt.r.tokens) != maxTokenSenders {
		t.Errorf("%d senders", len(tt.r.tokens))
	}
	tt.now = tt.now.Add(tokenSenderIdle)
	if n := tt.send(0, "sync:1", tokensRefusedMetric+":5|c\n"+lineGet); n != 3 || len(tt.r.tokens) != 1 {
		t.Errorf("after the quiet ones: %d refused, %d senders", n, len(tt.r.tokens))
	}
	if _, ok := tt.r.cumulative[tokensRefusedMetric]; ok {
		t.Error("in the statsd totals")
	}
}

// TestTokensRefusedTraffic: counted with the errors of the minute, the verification
// already in its requests
func TestTokensRefusedTraffic(t *testing.T) {
	tt := newTokenTest()
	tt.send(0, "sync:1", lineVerified+lineGet)
	tt.send(time.Minute, "sync:1", lineGet)
	from := tt.minute() - 60000
	if tr := tt.tally.TrafficBetween(from, from+60000); tr.Errors != 1 || tr.Requests != 2 {
		t.Errorf("%+v", tr)
	}
}

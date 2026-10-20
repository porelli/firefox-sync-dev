package main

import (
	"time"
)

// The tokens refused, from the token requests verified (syncstorage.token_verification)
// and the tokens issued (syncstorage.token_creation) in the order the Sync server sent
// them. syncstorage-rs sends the verification at the end of the request's extractor and
// the token at the end of its handler: in between it reads and updates the user in the
// tokenserver database, waiting for a connection at most
// SYNC_TOKENSERVER__DATABASE_POOL_CONNECTION_TIMEOUT (30 s by default). It sends its
// metrics when 512 bytes are buffered, other requests' lines between the two. So a
// token, when there is one, is buffered at most tokenWait after its verification; a
// datagram of the same sender that comes later was sent after it was buffered and
// brought it, or one before it did. A verification still open then is refused.

const (
	// the pool's 30 s for a connection, and its queries
	tokenWait = 40 * time.Second
	// verifications still open per sender: over it the oldest is refused
	maxOpenTokens = 10000
	// senders followed at once (a Sync server sends from one port for these): over it the
	// one quiet the longest is dropped
	maxTokenSenders = 16
	// a sender quiet that long is dropped, its open verifications not counted (a Sync
	// server restarted sends from another port, what it had buffered is gone)
	tokenSenderIdle = 10 * time.Minute
)

// openToken: a verification without its token yet, when it came, and the minute the
// recorder wrote it in (0: not written yet)
type openToken struct {
	at     time.Time
	minute int64
}

// tokenStream: the open verifications of a sender, oldest first. One stream per sender
// address: syncstorage-rs sends the token timers from one socket, several Sync servers
// (or one restarted) do not mix
type tokenStream struct {
	open []openToken
	seen time.Time
}

// tokenStream of a sender, with r.mu held
func (r *Recorder) tokenStream(sender string, now time.Time) *tokenStream {
	if r.tokens == nil {
		r.tokens = map[string]*tokenStream{}
	}
	s := r.tokens[sender]
	if s == nil {
		if len(r.tokens) >= maxTokenSenders {
			quiet := ""
			for k, o := range r.tokens {
				if quiet == "" || o.seen.Before(r.tokens[quiet].seen) {
					quiet = k
				}
			}
			delete(r.tokens, quiet)
		}
		s = &tokenStream{}
		r.tokens[sender] = s
	}
	s.seen = now
	return s
}

// tokenLine follows a line of a datagram, with r.mu held: a token pays off the latest
// open verification. Not the oldest: under steady sign-ins a refused one would be paid
// off by the next request's token, that request's verification by the next one's, and
// the one left open would never be tokenWait old. The latest leaves a refused one open
// to age; a slow token that pays off a newer refused one instead leaves its own
// verification open: one refused all the same, in the minute of the other
func (r *Recorder) tokenLine(s *tokenStream, name string, now time.Time) {
	switch name {
	case tokenVerified:
		if len(s.open) >= maxOpenTokens {
			r.refuseToken(s.open[0])
			s.open = s.open[1:]
		}
		s.open = append(s.open, openToken{at: now})
	case tokenIssued:
		if len(s.open) > 0 {
			s.open = s.open[:len(s.open)-1]
		}
	}
}

// tokenDatagram ends a datagram of the sender, with r.mu held: the verifications open
// for tokenWait are refused
func (r *Recorder) tokenDatagram(s *tokenStream, now time.Time) {
	for len(s.open) > 0 && now.Sub(s.open[0].at) >= tokenWait {
		r.refuseToken(s.open[0])
		s.open = s.open[1:]
	}
}

// refuseToken counts a token refused in the minute its verification was written in,
// with r.mu held
func (r *Recorder) refuseToken(t openToken) {
	if t.minute == 0 {
		r.currentMetric(tokensRefusedMetric).count++
		return
	}
	if r.refusedAt == nil {
		r.refusedAt = map[int64]int64{}
	}
	r.refusedAt[t.minute]++
}

// tokensWritten: the open verifications are in the minute being written, with r.mu
// held; the senders quiet for tokenSenderIdle dropped
func (r *Recorder) tokensWritten(minute int64, now time.Time) {
	for k, s := range r.tokens {
		if now.Sub(s.seen) >= tokenSenderIdle {
			delete(r.tokens, k)
			continue
		}
		for i := range s.open {
			if s.open[i].minute == 0 {
				s.open[i].minute = minute
			}
		}
	}
}

// currentMetric: the counter of the metric in the minute being recorded, with r.mu held
func (r *Recorder) currentMetric(name string) *metric {
	m := r.current[name]
	if m == nil {
		m = &metric{}
		r.current[name] = m
	}
	return m
}

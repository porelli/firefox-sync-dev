package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The rate limits of the accounts service, from its Redis:
//   rate-limit:attempts:<on>=<value>:<action>:<max>-<window>-<ban>  attempts so far
//   rate-limit:block:<same>                                          an active block (JSON)
// <on> is ip, email, ip_email, uid or ip_uid.

type Block struct {
	Key      string
	Action   string
	On       string
	Value    string
	Attempts int
	Until    time.Time
}

type Attempts struct {
	Action string
	On     string
	Value  string
	Count  int
	Max    int
	Window time.Duration
}

// failed attempts worth watching: guessing passwords or codes
var watchedActions = map[string]bool{
	"accountLogin": true, "passwordCheckFailed": true, "accountStatusCheckFailed": true,
	"loadAccountFailed": true, "recoveryEmailVerifyCode": true, "unblockEmail": true,
	"accountCreate": true, "verifyTotpCode": true, "verifyRecoveryCode": true,
}

// parseRateLimitKey splits rate-limit:<kind>:<on>=<value>:<action>:<max>-<window>-<ban>.
// Values can contain ':' (IPv6), the action and the rule are the last two parts.
func parseRateLimitKey(key string) (kind, on, value, action string, max int, window time.Duration, ok bool) {
	rest, found := strings.CutPrefix(key, "rate-limit:")
	if !found {
		return
	}
	kind, rest, found = strings.Cut(rest, ":")
	if !found {
		return
	}
	i := strings.LastIndex(rest, ":")
	if i < 0 {
		return
	}
	rule := strings.Split(rest[i+1:], "-")
	rest = rest[:i]
	j := strings.LastIndex(rest, ":")
	if j < 0 || len(rule) != 3 {
		return
	}
	action, rest = rest[j+1:], rest[:j]
	on, value, found = strings.Cut(rest, "=")
	if !found {
		return
	}
	max, _ = strconv.Atoi(rule[0])
	seconds, _ := strconv.Atoi(rule[1])
	return kind, on, value, action, max, time.Duration(seconds) * time.Second, true
}

func (f *FxaDB) RateLimits(ctx context.Context) ([]Block, []Attempts, error) {
	conn, err := dialRedis(ctx, f.redis)
	if err != nil {
		return nil, nil, err
	}
	defer conn.Close()
	var blocks []Block
	keys, err := conn.Scan("rate-limit:block:*", 1000)
	if err != nil {
		return nil, nil, err
	}
	for _, key := range keys {
		_, on, value, action, _, _, ok := parseRateLimitKey(key)
		if !ok {
			continue
		}
		b := Block{Key: key, Action: action, On: on, Value: value}
		if raw, err := conn.Do("GET", key); err == nil {
			var info struct {
				StartTime int64 `json:"startTime"`
				Duration  int64 `json:"duration"`
				Attempts  int   `json:"attempts"`
			}
			if s, ok := raw.(string); ok && json.Unmarshal([]byte(s), &info) == nil {
				b.Attempts = info.Attempts
				b.Until = time.UnixMilli(info.StartTime).Add(time.Duration(info.Duration) * time.Second)
			}
		}
		blocks = append(blocks, b)
	}
	sort.Slice(blocks, func(i, j int) bool { return blocks[i].Until.After(blocks[j].Until) })

	var attempts []Attempts
	keys, err = conn.Scan("rate-limit:attempts:*", 5000)
	if err != nil {
		return nil, nil, err
	}
	for _, key := range keys {
		_, on, value, action, max, window, ok := parseRateLimitKey(key)
		if !ok || !watchedActions[action] {
			continue
		}
		raw, err := conn.Do("GET", key)
		if err != nil {
			continue
		}
		s, _ := raw.(string)
		count, _ := strconv.Atoi(s)
		// half way to the limit or more
		if max > 0 && count*2 >= max {
			attempts = append(attempts, Attempts{action, on, value, count, max, window})
		}
	}
	sort.Slice(attempts, func(i, j int) bool {
		return float64(attempts[i].Count)/float64(attempts[i].Max) > float64(attempts[j].Count)/float64(attempts[j].Max)
	})
	if len(attempts) > 100 {
		attempts = attempts[:100]
	}
	return blocks, attempts, nil
}

// Unblock lifts a block before it ends (and resets its attempts)
func (f *FxaDB) Unblock(ctx context.Context, key string) error {
	kind, _, _, _, _, _, ok := parseRateLimitKey(key)
	if !ok || kind != "block" {
		return fmt.Errorf("not a block")
	}
	conn, err := dialRedis(ctx, f.redis)
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = conn.Do("DEL", key, "rate-limit:attempts:"+strings.TrimPrefix(key, "rate-limit:block:"))
	return err
}

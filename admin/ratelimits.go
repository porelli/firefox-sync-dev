package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
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
	Start    time.Time
	Until    time.Time
}

// Subject is the email or the uid a block is on, lower case ("" for an IP address
// alone): ip_email values are <ip>_<email>, ip_uid <ip>_<uid> (IP addresses have no _)
func (b Block) Subject() (email, uid string) {
	value := strings.ToLower(b.Value)
	switch b.On {
	case "email":
		return value, ""
	case "uid":
		return "", value
	case "ip_email":
		_, email, _ := strings.Cut(value, "_")
		return email, ""
	case "ip_uid":
		_, uid, _ := strings.Cut(value, "_")
		return "", uid
	}
	return "", ""
}

// blocksOf: the blocks of an account (its email or uid)
func blocksOf(blocks []Block, acc *FxaAccount) []Block {
	var mine []Block
	for _, b := range blocks {
		if email, uid := b.Subject(); (email != "" && email == strings.ToLower(acc.Email)) || (uid != "" && uid == acc.UID) {
			mine = append(mine, b)
		}
	}
	return mine
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

// Anybody can create blocks, by trying unknown emails or from many addresses: the
// key names are read in full (up to maxBlockKeys), only the blocks that matter are
// read (MGET), so a flood of strangers' blocks cannot push a member's out of sight
var maxBlockKeys = 100000

func tooManyBlocks() string {
	return fmt.Sprintf("Rate limits: more than %d blocks (someone is flooding the accounts service?), only the first %[1]d were checked", maxBlockKeys)
}

// listed on the Security page, after the blocks of accounts
const maxListedBlocks = 1000

// blockKeys: the active blocks from their key names alone; complete is false past
// maxBlockKeys
func blockKeys(conn *redisConn) (blocks []Block, complete bool, err error) {
	keys, complete, err := conn.Scan("rate-limit:block:*", maxBlockKeys)
	if err != nil {
		return nil, false, err
	}
	if !complete {
		log.Printf("more than %d rate limit blocks, the rest are not checked", maxBlockKeys)
	}
	for _, key := range keys {
		if _, on, value, action, _, _, ok := parseRateLimitKey(key); ok {
			blocks = append(blocks, Block{Key: key, Action: action, On: on, Value: value})
		}
	}
	return blocks, complete, nil
}

// fillBlocks reads when the blocks started and end, the latest to end first
func fillBlocks(conn *redisConn, blocks []Block) error {
	for i := 0; i < len(blocks); i += 500 {
		batch := blocks[i:min(i+500, len(blocks))]
		args := []string{"MGET"}
		for _, b := range batch {
			args = append(args, b.Key)
		}
		reply, err := conn.Do(args...)
		if err != nil {
			return err
		}
		values, _ := reply.([]any)
		for j := range batch {
			if j >= len(values) {
				break
			}
			var info struct {
				StartTime int64 `json:"startTime"`
				Duration  int64 `json:"duration"`
				Attempts  int   `json:"attempts"`
			}
			if s, ok := values[j].(string); ok && json.Unmarshal([]byte(s), &info) == nil {
				b := &batch[j]
				b.Attempts, b.Start = info.Attempts, time.UnixMilli(info.StartTime)
				b.Until = b.Start.Add(time.Duration(info.Duration) * time.Second)
			}
		}
	}
	sort.SliceStable(blocks, func(i, j int) bool { return blocks[i].Until.After(blocks[j].Until) })
	return nil
}

// ofAccounts splits the blocks into those of the accounts (by email or uid) and the others
func ofAccounts(blocks []Block, accounts []FxaAccount) (mine, others []Block) {
	emails, uids := map[string]bool{}, map[string]bool{}
	for _, acc := range accounts {
		emails[strings.ToLower(acc.Email)], uids[acc.UID] = true, true
	}
	for _, b := range blocks {
		if email, uid := b.Subject(); (email != "" && emails[email]) || (uid != "" && uids[uid]) {
			mine = append(mine, b)
		} else {
			others = append(others, b)
		}
	}
	return mine, others
}

// BlocksOf: the active blocks of these accounts, the latest to end first; complete
// is false when there were too many blocks to look at them all
func (f *FxaDB) BlocksOf(ctx context.Context, accounts []FxaAccount) ([]Block, bool, error) {
	conn, err := dialRedis(ctx, f.redis)
	if err != nil {
		return nil, false, err
	}
	defer conn.Close()
	all, complete, err := blockKeys(conn)
	if err != nil {
		return nil, false, err
	}
	mine, _ := ofAccounts(all, accounts)
	return mine, complete, fillBlocks(conn, mine)
}

type Limits struct {
	Blocks   []Block
	Hidden   int  // blocks of strangers not listed
	Complete bool // false: more than maxBlockKeys, some were not even counted
	Attempts []Attempts
}

// RateLimits: the blocks of accounts, then the others up to maxListedBlocks, and the
// attempts close to a limit
func (f *FxaDB) RateLimits(ctx context.Context) (Limits, error) {
	var l Limits
	accounts, err := f.Accounts(ctx)
	if err != nil {
		return l, err
	}
	conn, err := dialRedis(ctx, f.redis)
	if err != nil {
		return l, err
	}
	defer conn.Close()
	all, complete, err := blockKeys(conn)
	if err != nil {
		return l, err
	}
	l.Complete = complete
	mine, others := ofAccounts(all, accounts)
	if room := max(maxListedBlocks-len(mine), 0); len(others) > room {
		l.Hidden, others = len(others)-room, others[:room]
	}
	l.Blocks = append(mine, others...)
	if err := fillBlocks(conn, l.Blocks); err != nil {
		return l, err
	}

	keys, _, err := conn.Scan("rate-limit:attempts:*", 5000)
	if err != nil {
		return l, err
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
			l.Attempts = append(l.Attempts, Attempts{action, on, value, count, max, window})
		}
	}
	sort.Slice(l.Attempts, func(i, j int) bool {
		return float64(l.Attempts[i].Count)/float64(l.Attempts[i].Max) > float64(l.Attempts[j].Count)/float64(l.Attempts[j].Max)
	})
	if len(l.Attempts) > 100 {
		l.Attempts = l.Attempts[:100]
	}
	return l, nil
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

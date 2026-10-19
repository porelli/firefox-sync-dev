package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// Just enough of the Redis protocol to revoke the access tokens of an account: FxA
// keeps them in Redis only (ACCESS_TOKEN_REDIS_HOST), as at:<token id> keys listed in
// the set at:<uid>. Its session cache is fxa-auth-session<uid>, the last use of the
// refresh tokens rt:<uid>.
const revokeScript = `
local ids = redis.call('smembers', KEYS[1])
for _, id in ipairs(ids) do redis.call('del', id) end
redis.call('del', KEYS[1], KEYS[2], KEYS[3])
return #ids`

// redisConn is one connection, for a few commands
type redisConn struct {
	conn net.Conn
	r    *bufio.Reader
}

func dialRedis(ctx context.Context, addr string) (*redisConn, error) {
	dialer := net.Dialer{Timeout: 5 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	c := &redisConn{conn: conn, r: bufio.NewReader(conn)}
	// a Redis with a password (the Helm chart's, FXA_REDIS_PASSWORD): signed in first
	if password := os.Getenv("FXA_REDIS_PASSWORD"); password != "" {
		if _, err := c.Do("AUTH", password); err != nil {
			conn.Close()
			return nil, err
		}
	}
	return c, nil
}

func (c *redisConn) Close() error { return c.conn.Close() }

func (c *redisConn) Do(args ...string) (any, error) {
	if err := writeCommand(c.conn, args); err != nil {
		return nil, err
	}
	return readReply(c.r)
}

// Scan returns the keys matching pattern, stopping at limit (complete false)
func (c *redisConn) Scan(pattern string, limit int) (keys []string, complete bool, err error) {
	cursor := "0"
	for {
		reply, err := c.Do("SCAN", cursor, "MATCH", pattern, "COUNT", "1000")
		if err != nil {
			return nil, false, err
		}
		parts, ok := reply.([]any)
		if !ok || len(parts) != 2 {
			return nil, false, fmt.Errorf("unexpected SCAN reply")
		}
		cursor, _ = parts[0].(string)
		items, _ := parts[1].([]any)
		for _, k := range items {
			if s, ok := k.(string); ok {
				keys = append(keys, s)
			}
		}
		if cursor == "0" || cursor == "" {
			return keys, true, nil
		}
		if len(keys) >= limit {
			return keys, false, nil
		}
	}
}

func revokeRedisTokens(ctx context.Context, addr, uid string) (int64, error) {
	conn, err := dialRedis(ctx, addr)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	reply, err := conn.Do("EVAL", revokeScript, "3", "at:"+uid, "fxa-auth-session"+uid, "rt:"+uid)
	if err != nil {
		return 0, err
	}
	n, ok := reply.(int64)
	if !ok {
		return 0, fmt.Errorf("unexpected reply %v", reply)
	}
	return n, nil
}

// sessionsLastUsed reads when each session of an account was last used from the
// accounts service's cache (fxa-auth-session<uid>: JSON by token id, each a packed
// array starting with lastAccessTime, or an object in older versions). By session ref:
// the token ids sign in as the account, they never leave this function
func sessionsLastUsed(ctx context.Context, addr, uid string) (map[string]time.Time, error) {
	conn, err := dialRedis(ctx, addr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	reply, err := conn.Do("GET", "fxa-auth-session"+uid)
	if err != nil || reply == nil {
		return nil, err
	}
	raw, _ := reply.(string)
	return parseSessionCache(raw)
}

// sessionsLastUsedOf: sessionsLastUsed of many accounts over one connection, an MGET per
// batch. The accounts whose cache cannot be read are in bad
func sessionsLastUsedOf(ctx context.Context, addr string, uids []string) (used map[string]map[string]time.Time, bad []string, err error) {
	used = map[string]map[string]time.Time{}
	if len(uids) == 0 {
		return used, nil, nil
	}
	conn, err := dialRedis(ctx, addr)
	if err != nil {
		return nil, nil, err
	}
	defer conn.Close()
	const batch = 500
	for from := 0; from < len(uids); from += batch {
		part := uids[from:min(from+batch, len(uids))]
		args := []string{"MGET"}
		for _, uid := range part {
			args = append(args, "fxa-auth-session"+uid)
		}
		reply, err := conn.Do(args...)
		if err != nil {
			return nil, nil, err
		}
		values, ok := reply.([]any)
		if !ok || len(values) != len(part) {
			return nil, nil, errors.New("unexpected MGET reply")
		}
		for i, v := range values {
			if v == nil {
				continue
			}
			raw, _ := v.(string)
			times, err := parseSessionCache(raw)
			if err != nil {
				bad = append(bad, part[i])
				continue
			}
			used[part[i]] = times
		}
	}
	return used, bad, nil
}

func parseSessionCache(raw string) (map[string]time.Time, error) {
	var tokens map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &tokens); err != nil {
		return nil, errors.New("unexpected session cache") // not the error: it may quote the JSON
	}
	used := map[string]time.Time{}
	for id, value := range tokens {
		token, err := hex.DecodeString(id)
		if err != nil {
			continue
		}
		sum := sha256.Sum256(token)
		ref := hex.EncodeToString(sum[:])
		var last float64
		var packed []json.RawMessage
		var object struct {
			LastAccessTime float64 `json:"lastAccessTime"`
		}
		switch {
		case json.Unmarshal(value, &packed) == nil:
			if len(packed) > 0 {
				json.Unmarshal(packed[0], &last)
			}
		case json.Unmarshal(value, &object) == nil:
			last = object.LastAccessTime
		}
		if last > 0 {
			used[ref] = time.UnixMilli(int64(last))
		}
	}
	return used, nil
}

// dropProfileCache removes an account from the profile server's cache (catbox: the
// partition fxa-profile, the segment of the method, the key URI-encoded): the uid for
// the profile scope, and the one of the untrusted reliers' scopes
func dropProfileCache(ctx context.Context, addr, uid string) error {
	conn, err := dialRedis(ctx, addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	const prefix = "fxa-profile:%23profileCache.get:"
	_, err = conn.Do("DEL", prefix+uid, prefix+uid+"%3Ascoped%3Adisplay_name%2Bemail%2Buid")
	return err
}

func writeCommand(w io.Writer, args []string) error {
	var b strings.Builder
	fmt.Fprintf(&b, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(&b, "$%d\r\n%s\r\n", len(a), a)
	}
	_, err := io.WriteString(w, b.String())
	return err
}

func redisCommand(conn io.ReadWriter, args ...string) (any, error) {
	if err := writeCommand(conn, args); err != nil {
		return nil, err
	}
	return readReply(bufio.NewReader(conn))
}

func readReply(r *bufio.Reader) (any, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	line = strings.TrimSuffix(line, "\r\n")
	if line == "" {
		return nil, errors.New("empty reply")
	}
	switch line[0] {
	case '+':
		return line[1:], nil
	case '-':
		return nil, errors.New("redis: " + line[1:])
	case ':':
		return strconv.ParseInt(line[1:], 10, 64)
	case '$':
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil // nil bulk string: no such key
		}
		buf := make([]byte, n+2)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, err
		}
		return string(buf[:n]), nil
	case '*':
		n, err := strconv.Atoi(line[1:])
		if err != nil || n < 0 {
			return nil, err
		}
		items := make([]any, n)
		for i := range items {
			if items[i], err = readReply(r); err != nil {
				return nil, err
			}
		}
		return items, nil
	}
	return nil, fmt.Errorf("unexpected reply %q", line)
}

package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

// Just enough of the Redis protocol to revoke the access tokens of an account: FxA
// keeps them in Redis only (ACCESS_TOKEN_REDIS_HOST), as at:<token id> keys listed in
// the set at:<uid>. Its session cache is fxa-auth-session<uid>.
const revokeScript = `
local ids = redis.call('smembers', KEYS[1])
for _, id in ipairs(ids) do redis.call('del', id) end
redis.call('del', KEYS[1], KEYS[2])
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
	return &redisConn{conn: conn, r: bufio.NewReader(conn)}, nil
}

func (c *redisConn) Close() error { return c.conn.Close() }

func (c *redisConn) Do(args ...string) (any, error) {
	if err := writeCommand(c.conn, args); err != nil {
		return nil, err
	}
	return readReply(c.r)
}

// Scan returns the keys matching pattern, at most limit
func (c *redisConn) Scan(pattern string, limit int) ([]string, error) {
	var keys []string
	cursor := "0"
	for {
		reply, err := c.Do("SCAN", cursor, "MATCH", pattern, "COUNT", "500")
		if err != nil {
			return nil, err
		}
		parts, ok := reply.([]any)
		if !ok || len(parts) != 2 {
			return nil, fmt.Errorf("unexpected SCAN reply")
		}
		cursor, _ = parts[0].(string)
		items, _ := parts[1].([]any)
		for _, k := range items {
			if s, ok := k.(string); ok {
				keys = append(keys, s)
			}
		}
		if cursor == "0" || cursor == "" || len(keys) >= limit {
			return keys, nil
		}
	}
}

func revokeRedisTokens(ctx context.Context, addr, uid string) (int64, error) {
	conn, err := dialRedis(ctx, addr)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	reply, err := conn.Do("EVAL", revokeScript, "2", "at:"+uid, "fxa-auth-session"+uid)
	if err != nil {
		return 0, err
	}
	n, ok := reply.(int64)
	if !ok {
		return 0, fmt.Errorf("unexpected reply %v", reply)
	}
	return n, nil
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

package network

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/vmihailenco/msgpack/v5"

	"tetris-royale/internal/game"
)

const (
	writeWait       = 5 * time.Second
	readLimit       = 4096
	sessionTTL      = 30 * time.Minute
	maxActionsPerS  = 15
	stateEveryTicks = 1
)

type Handler struct {
	db            *pgxpool.Pool
	redis         *redis.Client
	allowedOrigin string
	upgrader      websocket.Upgrader
}

func NewHandler(db *pgxpool.Pool, redisClient *redis.Client, allowedOrigin string) *Handler {
	h := &Handler{db: db, redis: redisClient, allowedOrigin: allowedOrigin}
	h.upgrader = websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 2048,
		CheckOrigin:     h.checkOrigin,
	}
	return h
}

func (h *Handler) ServeWS(w http.ResponseWriter, r *http.Request) {
	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade failed: %v", err)
		return
	}

	sessionID := newUUID()
	seed := randomSeed()
	s := &session{
		id:          sessionID,
		seed:        seed,
		conn:        conn,
		db:          h.db,
		redis:       h.redis,
		inputs:      make(chan game.Input, 128),
		done:        make(chan struct{}),
		rateLimiter: game.NewRateLimiter(maxActionsPerS),
		state:       game.NewState(seed),
	}
	s.currentTick.Store(s.state.Tick)

	go s.readLoop()
	s.run()
}

func (h *Handler) checkOrigin(r *http.Request) bool {
	if h.allowedOrigin == "" || h.allowedOrigin == "*" {
		return true
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	for _, allowed := range strings.Split(h.allowedOrigin, ",") {
		if strings.TrimSpace(allowed) == origin {
			return true
		}
	}
	return false
}

type session struct {
	id          string
	seed        uint64
	conn        *websocket.Conn
	db          *pgxpool.Pool
	redis       *redis.Client
	inputs      chan game.Input
	done        chan struct{}
	closeOnce   sync.Once
	writeMu     sync.Mutex
	rateLimiter *game.RateLimiter
	currentTick atomic.Uint64
	state       game.State
}

func (s *session) run() {
	defer func() {
		s.closeDone()
		_ = s.conn.Close()
		s.finishMatch(context.Background())
	}()

	ctx := context.Background()
	s.startMatch(ctx)

	if err := s.writeEnvelope(map[string]any{
		"t":           "hello",
		"player_id":   s.id,
		"tick_rate":   game.TickRate,
		"input_delay": game.InputDelayTicks,
		"seed":        s.seed,
	}); err != nil {
		log.Printf("hello write failed: %v", err)
		return
	}
	if err := s.sendState(true); err != nil {
		log.Printf("initial state write failed: %v", err)
		return
	}

	ticker := time.NewTicker(time.Second / game.TickRate)
	defer ticker.Stop()

	var pending []game.Input
	for {
		select {
		case <-s.done:
			return
		case input := <-s.inputs:
			pending = append(pending, input)
		case <-ticker.C:
			pending = drainInputs(s.inputs, pending)
			due := make([]game.Input, 0, len(pending))
			future := pending[:0]
			for _, input := range pending {
				if input.Tick <= s.state.Tick {
					due = append(due, input)
				} else {
					future = append(future, input)
				}
			}
			pending = future
			s.state = game.Step(s.state, due)
			s.currentTick.Store(s.state.Tick)

			if s.state.Tick%stateEveryTicks == 0 {
				if err := s.sendState(false); err != nil {
					log.Printf("state write failed: %v", err)
					return
				}
			}
		}
	}
}

func (s *session) readLoop() {
	defer func() {
		s.closeDone()
	}()

	s.conn.SetReadLimit(readLimit)
	_ = s.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	s.conn.SetPongHandler(func(string) error {
		_ = s.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		messageType, data, err := s.conn.ReadMessage()
		if err != nil {
			if !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				log.Printf("read failed: %v", err)
			}
			return
		}
		if messageType != websocket.BinaryMessage {
			_ = s.closeWithReason(websocket.CloseUnsupportedData, "binary_message_required")
			return
		}

		input, err := decodeInput(data)
		if err != nil {
			_ = s.closeWithReason(websocket.CloseUnsupportedData, "bad_message")
			return
		}
		if err := game.ValidateInput(input, s.currentTick.Load(), s.rateLimiter, time.Now()); err != nil {
			reason := "invalid_input"
			if errors.Is(err, game.ErrRateLimited) {
				reason = "rate_limited"
			}
			_ = s.closeWithReason(websocket.ClosePolicyViolation, reason)
			return
		}

		select {
		case s.inputs <- input:
		case <-s.done:
			return
		default:
			_ = s.closeWithReason(websocket.ClosePolicyViolation, "input_queue_overflow")
			return
		}
	}
}

func drainInputs(ch <-chan game.Input, pending []game.Input) []game.Input {
	for {
		select {
		case input := <-ch:
			pending = append(pending, input)
		default:
			return pending
		}
	}
}

func decodeInput(data []byte) (game.Input, error) {
	var msg map[string]any
	if err := msgpack.Unmarshal(data, &msg); err != nil {
		return game.Input{}, err
	}
	if asString(msg["t"]) != "input" {
		return game.Input{}, errors.New("not an input message")
	}
	return game.Input{
		Tick:       asUint64(msg["tick"]),
		Seq:        asUint64(msg["seq"]),
		Action:     game.InputAction(asUint64(msg["action"])),
		ClientHash: asString(msg["hash"]),
	}, nil
}

func (s *session) sendState(force bool) error {
	snap := s.state.Snapshot()
	return s.writeEnvelope(map[string]any{
		"t":             "state",
		"force":         force,
		"merkle_period": game.TickRate,
		"state":         snap,
	})
}

func (s *session) writeEnvelope(payload map[string]any) error {
	data, err := msgpack.Marshal(payload)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.conn.SetWriteDeadline(time.Now().Add(writeWait))
	return s.conn.WriteMessage(websocket.BinaryMessage, data)
}

func (s *session) closeWithReason(code int, reason string) error {
	msg := websocket.FormatCloseMessage(code, reason)
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.conn.SetWriteDeadline(time.Now().Add(writeWait))
	return s.conn.WriteMessage(websocket.CloseMessage, msg)
}

func (s *session) closeDone() {
	s.closeOnce.Do(func() {
		close(s.done)
	})
}

func (s *session) startMatch(ctx context.Context) {
	if s.redis != nil {
		if err := s.redis.Set(ctx, "session:"+s.id, "connected", sessionTTL).Err(); err != nil {
			log.Printf("redis session set failed: %v", err)
		}
	}
	if s.db != nil {
		_, err := s.db.Exec(ctx, `
			insert into matches (id, seed, status, started_at, last_hash)
			values ($1, $2, 'running', now(), $3)
			on conflict (id) do nothing
		`, s.id, int64(s.seed&0x7fffffffffffffff), game.HashHex(s.state))
		if err != nil {
			log.Printf("match insert failed: %v", err)
		}
	}
}

func (s *session) finishMatch(ctx context.Context) {
	if s.redis != nil {
		if err := s.redis.Del(ctx, "session:"+s.id).Err(); err != nil {
			log.Printf("redis session delete failed: %v", err)
		}
	}
	if s.db != nil {
		_, err := s.db.Exec(ctx, `
			update matches
			set status = case when status = 'running' then 'finished' else status end,
			    ended_at = coalesce(ended_at, now()),
			    tick_count = $2,
			    last_hash = $3
			where id = $1
		`, s.id, int64(s.state.Tick), game.HashHex(s.state))
		if err != nil {
			log.Printf("match update failed: %v", err)
		}
	}
}

func asString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case []byte:
		return string(t)
	default:
		return ""
	}
}

func asUint64(v any) uint64 {
	switch t := v.(type) {
	case uint64:
		return t
	case uint32:
		return uint64(t)
	case uint16:
		return uint64(t)
	case uint8:
		return uint64(t)
	case uint:
		return uint64(t)
	case int64:
		return uint64(t)
	case int32:
		return uint64(t)
	case int16:
		return uint64(t)
	case int8:
		return uint64(t)
	case int:
		return uint64(t)
	default:
		return 0
	}
}

func randomSeed() uint64 {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return uint64(time.Now().UnixNano()) & 0x7fffffffffffffff
	}
	return binary.LittleEndian.Uint64(buf[:]) & 0x7fffffffffffffff
}

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		now := uint64(time.Now().UnixNano())
		binary.LittleEndian.PutUint64(b[:8], now)
		binary.LittleEndian.PutUint64(b[8:], now^0x9e3779b97f4a7c15)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(b[:])
	return hexed[0:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" + hexed[16:20] + "-" + hexed[20:32]
}

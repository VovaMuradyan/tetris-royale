package game

import (
	"errors"
	"time"
)

var (
	ErrInvalidAction = errors.New("invalid action")
	ErrRateLimited   = errors.New("rate limited")
	ErrInputTooOld   = errors.New("input tick is too old")
	ErrInputTooNew   = errors.New("input tick is too far ahead")
	ErrHashMismatch  = errors.New("state hash mismatch")
)

type RateLimiter struct {
	limit  int
	events []time.Time
}

func NewRateLimiter(limitPerSecond int) *RateLimiter {
	return &RateLimiter{limit: limitPerSecond}
}

func (r *RateLimiter) Allow(now time.Time) bool {
	if r == nil || r.limit <= 0 {
		return true
	}
	cutoff := now.Add(-time.Second)
	write := 0
	for _, event := range r.events {
		if event.After(cutoff) {
			r.events[write] = event
			write++
		}
	}
	r.events = r.events[:write]
	if len(r.events) >= r.limit {
		return false
	}
	r.events = append(r.events, now)
	return true
}

func ValidateInput(input Input, serverTick uint64, limiter *RateLimiter, now time.Time) error {
	if !input.Action.Valid() {
		return ErrInvalidAction
	}
	if input.Tick+MaxInputLagTicks < serverTick {
		return ErrInputTooOld
	}
	if input.Tick > serverTick+MaxInputLeadTicks {
		return ErrInputTooNew
	}
	if input.Action != ActionNone && !limiter.Allow(now) {
		return ErrRateLimited
	}
	return nil
}

func ValidateClientHash(s State, clientHash string) error {
	if clientHash == "" {
		return nil
	}
	if clientHash != HashHex(s) {
		return ErrHashMismatch
	}
	return nil
}

func (a InputAction) Valid() bool {
	return a <= ActionHardDrop
}

package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"tetris-royale/internal/network"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	db := connectPostgres(ctx, os.Getenv("DATABASE_URL"))
	if db != nil {
		defer db.Close()
	}

	cache := connectRedis(ctx, os.Getenv("REDIS_URL"))
	if cache != nil {
		defer cache.Close()
	}

	handler := network.NewHandler(db, cache, os.Getenv("ALLOWED_ORIGIN"))

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/ws", handler.ServeWS)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("tetris royale backend listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("http server failed: %v", err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
}

func connectPostgres(ctx context.Context, databaseURL string) *pgxpool.Pool {
	if databaseURL == "" {
		log.Printf("DATABASE_URL is empty; persistence disabled")
		return nil
	}

	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		log.Printf("invalid DATABASE_URL: %v", err)
		return nil
	}
	cfg.MaxConns = 2
	cfg.MinConns = 0
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Printf("postgres connect failed: %v", err)
		return nil
	}
	if err := pool.Ping(ctx); err != nil {
		log.Printf("postgres ping failed: %v", err)
		pool.Close()
		return nil
	}
	log.Printf("postgres connected")
	return pool
}

func connectRedis(ctx context.Context, redisURL string) *redis.Client {
	if redisURL == "" {
		log.Printf("REDIS_URL is empty; session cache disabled")
		return nil
	}

	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Printf("invalid REDIS_URL: %v", err)
		return nil
	}
	opts.PoolSize = 2
	opts.MinIdleConns = 0

	client := redis.NewClient(opts)
	if err := client.Ping(ctx).Err(); err != nil {
		log.Printf("redis ping failed: %v", err)
		_ = client.Close()
		return nil
	}
	log.Printf("redis connected")
	return client
}

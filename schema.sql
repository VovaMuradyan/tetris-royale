create extension if not exists pgcrypto;

do $$
begin
  create type match_status as enum ('queued', 'running', 'finished', 'abandoned');
exception
  when duplicate_object then null;
end $$;

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  handle text unique,
  display_name text,
  rating integer not null default 1000,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);

create table if not exists matches (
  id uuid primary key default gen_random_uuid(),
  player_a uuid references users(id) on delete set null,
  player_b uuid references users(id) on delete set null,
  seed bigint not null,
  status match_status not null default 'queued',
  tick_count bigint not null default 0,
  winner_id uuid references users(id) on delete set null,
  last_hash text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz
);

create index if not exists matches_status_created_idx on matches (status, created_at desc);
create index if not exists matches_player_a_idx on matches (player_a);
create index if not exists matches_player_b_idx on matches (player_b);

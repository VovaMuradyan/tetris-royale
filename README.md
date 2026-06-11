# Tetris Royale

Server-authoritative Tetris на Go + Flutter, рассчитанный на бесплатные тарифы Supabase/Neon, Upstash и Render. Сервер держит 60 TPS, принимает ввод по WebSocket, считает состояние авторитетно и отправляет MessagePack state updates с Merkle/FNV-64 hash.

## Структура

- `main.go` - запуск HTTP/WebSocket сервера, PostgreSQL и Redis.
- `internal/game` - deterministic game core, fixed-point координаты, SRS, rate limiting.
- `internal/network` - WebSocket session loop, input queue, state broadcast.
- `lib/core/game_engine.dart` - Dart-порт ядра для client-side prediction.
- `lib/network/game_client.dart` - MessagePack WebSocket client, input buffer, reconciliation.
- `lib/ui/game_screen.dart` - Flutter CustomPainter поле 10x20 и touch controls.

## Локальный запуск

```powershell
go run .
```

В другом терминале:

```powershell
flutter pub get
flutter run --dart-define=GAME_WS_URL=ws://10.0.2.2:8080/ws
```

Для физического телефона замени `10.0.2.2` на LAN IP компьютера.

## Шаг 1: Supabase DATABASE_URL

1. Создай бесплатный проект на Supabase.
2. Открой SQL Editor и выполни `schema.sql`.
3. Открой Project Settings -> Database -> Connection string.
4. Скопируй URI вида `postgresql://postgres:<password>@...:5432/postgres`.
5. Это значение будет `DATABASE_URL`.

Neon.tech тоже подходит: создай free project, выполни `schema.sql`, возьми pooled connection string.

## Шаг 2: Upstash REDIS_URL

1. Создай бесплатную Redis database в Upstash.
2. Открой Details -> REST/Redis credentials.
3. Скопируй Redis URL вида `rediss://default:<password>@...:6379`.
4. Это значение будет `REDIS_URL`.

## Шаг 3: Render.com

1. Запушь репозиторий на GitHub.
2. В Render создай Blueprint или Web Service из репозитория.
3. Render прочитает `render.yaml` и соберёт Dockerfile.
4. В Environment Variables добавь:
   - `DATABASE_URL`
   - `REDIS_URL`
   - `ALLOWED_ORIGIN` (`*` для теста или домен клиента)
5. В Settings -> Deploy Hook скопируй URL.
6. В GitHub repo -> Settings -> Secrets and variables -> Actions добавь secret `RENDER_DEPLOY_HOOK_URL`.
7. При push в `main` workflow `.github/workflows/deploy.yml` выполнит `go test`, соберёт Docker image и дернёт Render deploy hook.

После деплоя WebSocket URL будет:

```text
wss://<your-render-service>.onrender.com/ws
```

## Шаг 4: Release .aab для Google Play

```powershell
flutter build appbundle --release --dart-define=GAME_WS_URL=wss://<your-render-service>.onrender.com/ws
```

Signed output:

```text
build/app/outputs/bundle/release/app-release.aab
```

Before Play submission, make sure you have:

1. A public privacy policy URL.
2. A completed Data safety form that matches the app's real Firebase and network usage.
3. Play App Signing enabled in Play Console.
4. A store listing with screenshots, icon, feature graphic, and content rating answers.
5. Internal testing uploaded first, then production after review.
6. The package name `com.tetris.royale` kept consistent everywhere.

Если локальный Flutter SDK попросит восстановить Android scaffold, выполни один раз:

```powershell
flutter create --platforms=android .
```

Затем повтори build command выше.

## Протокол

Клиент отправляет binary MessagePack:

```text
{ t: "input", tick, seq, action, hash }
```

Сервер отвечает:

```text
{ t: "state", force, merkle_period, state }
```

`action`: `0 none`, `1 left`, `2 right`, `3 rotate_cw`, `4 rotate_ccw`, `5 soft_drop`, `6 hard_drop`.

## Production notes

- Сервер ограничивает клиента до 15 игровых действий в секунду.
- Ввод старше 120 тиков или дальше 12 тиков вперёд отклоняется.
- Клиент буферизует ввод на 2 тика и делает optimistic local apply.
- При несовпадении authoritative snapshot hash клиент закрывает соединение с reason `cheat_detected`.
- Render free instance может засыпать; первый reconnect после простоя может занять несколько секунд.

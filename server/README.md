# Forum Badge server

> **For the editor / admin self-hosting the backend.** End users don't
> touch this — they just download the Mac app from the
> [homepage](https://ts7n.github.io/forum-badge/). You (the one editor
> running the bot account) host one of these, and everyone on staff points
> their app at it.

A tiny Node/Express proxy in front of FLOW. Holds the single session cookie,
caches aggressively, and exposes a small JSON API the Mac client uses. One
server per FLOW account; any number of clients point at it.

## Endpoints

- `GET /api/groups` — every group the bot has access to, as `[{id, name}, ...]`
- `GET /api/stories?ids=594,603` — stories submitted to the listed groups,
  with Google Doc links when FLOW has them
- `GET /api/verify` — returns `{ok: true}`. The Mac client hits this to check
  the user's password before unlocking the rest of the preferences UI.

All three require `Authorization: Bearer <FORUM_BADGE_PASSWORD>`.

`GET /healthz` is unauthed and reports refresh status.

## Configuration

Copy `.env.example` to `.env` and fill in:

- `FLOW_COOKIE` — full `Cookie:` header from an authenticated FLOW browser
  session. Sign in to <https://flow.snosites.com>, open Chrome DevTools →
  Network, click any `/api/v1/*` request, copy the `cookie` request header
  verbatim into `.env` (one line, no newlines).
- `FORUM_BADGE_PASSWORD` — bearer token the Mac client must present. Pick
  something long and random.
- `PORT` (optional, default `8787`)
- `REFRESH_INTERVAL_SECONDS` (optional, default `60`)

## Run with Docker (recommended)

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d --build
```

That's it. The image builds from the local `Dockerfile`, reads `.env` for
secrets, exposes the server on host port `8787`, and auto-restarts on reboot.

Change the host port without rebuilding:

```bash
HOST_PORT=9000 docker compose up -d
```

Tail logs:

```bash
docker compose logs -f
```

Rebuild after pulling code changes:

```bash
docker compose up -d --build
```

If you'd rather run the container directly without compose:

```bash
docker build -t forum-badge-server .
docker run -d --name forum-badge --env-file .env -p 8787:8787 \
  --restart unless-stopped forum-badge-server
```

## Run with Node directly

```bash
cp .env.example .env
$EDITOR .env
npm install
npm start
```

Requires Node 18+.

## How it caches

- Refreshes every `REFRESH_INTERVAL_SECONDS` (default 60s).
- Group list and the current assignment list are re-pulled every tick.
- Assignment *details* (title + `google_doc_id`) are fetched once per
  assignment id and reused forever — they don't change, and fetching them
  every tick would hammer FLOW.
- On failure, the previous snapshot stays served and `/healthz` reports
  `lastRefreshError` + `consecutiveFailures`.
- Rotated `Set-Cookie` values from FLOW are absorbed into the in-memory jar so
  the session stays fresh for as long as FLOW is willing to keep it.

## Operational notes

- Single Node process. If you need multiple replicas, switch to Redis (add
  `REDIS_URL` and plumb `cache.js` to read/write keys like
  `forum-badge:snapshot` / `forum-badge:assignment:<id>`).
- Logs go to stdout. Docker / your supervisor rotates them.
- The `FLOW_COOKIE` will die eventually — FLOW forces re-auth after some
  duration. When `/healthz` shows `consecutiveFailures` climbing, update `.env`
  with a fresh cookie and `docker compose up -d` (or restart the Node
  process).

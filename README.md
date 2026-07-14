# MySMS Messenger

Full-stack app for sending SMS messages and reviewing your own send history.
Stack: **Angular** SPA + **Ruby on Rails 7.1** JSON API (Mongoid/MongoDB) +
an outbound **Twilio** integration behind a swappable gateway abstraction.

See `doc/HLD.md` (architecture) and `doc/tech-design.md` (concrete design,
API contract, checkpoint plan) for full details.

## Prerequisites

- Ruby 3.3.x, Bundler
- Node.js + npm, Angular CLI (`npm install -g @angular/cli`, or use `npx ng`)
- Docker (for local MongoDB) — or a reachable MongoDB instance

## 1. Start MongoDB (Docker)

From the repo root:

```
docker compose up -d
```

This starts `mongo:7` on `localhost:27017` with a persistent named volume
(`mysms_mongo_data`). Stop it with `docker compose down` (add `-v` to also
wipe the data volume).

## 2. Backend (Rails API)

```
cd backend
bundle install
cp ../.env.example .env      # or export the vars in your shell
bin/rails server              # boots on http://localhost:3000
```

Health check: `curl http://localhost:3000/health` → `{"status":"ok"}`.

Run the test suite:

```
cd backend
bundle exec rspec
```

## 3. Frontend (Angular SPA)

```
cd frontend
npm install
ng serve                      # serves on http://localhost:4200
```

The frontend talks to the API at `environment.apiBaseUrl`
(`http://localhost:3000` in `src/environments/environment.development.ts`)
with `withCredentials: true`, so the backend's CORS config
(`backend/config/initializers/cors.rb`) must allow `http://localhost:4200`
with `credentials: true` — this is the default.

## Environment variables

See `.env.example` at the repo root for the full list with descriptions.
Summary:

| Variable | Purpose | Default |
|---|---|---|
| `MONGO_URI` | MongoDB connection string | `mongodb://localhost:27017/mysms_development` (required, no default, in production) |
| `MESSAGE_REPOSITORY` | `mongo` \| `in_memory` | `in_memory` in test, `mongo` elsewhere |
| `SMS_PROVIDER` | `fake` \| `twilio` | `fake` |
| `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_FROM_NUMBER` | Twilio credentials (required if `SMS_PROVIDER=twilio` — app raises a clear startup error otherwise) | blank |
| `CORS_ORIGINS` | Comma-separated allowed origins | `http://localhost:4200` |
| `CROSS_ORIGIN_COOKIES` | `true` to switch the `msms_owner` identity cookie to `SameSite=None; Secure` for genuine cross-origin deployments (requires HTTPS) | `false` (`SameSite=Lax`) |
| `SECRET_KEY_BASE` | Rails secret key base — required in production (no committed credentials file); generate with `bin/rails secret` | none in prod |
| `RACK_ATTACK_DISABLED` | Emergency bypass for the send-endpoint rate limit | `false` |

## Twilio status (CP11)

**Twilio credentials are not yet configured.** CityHive has not supplied
live Twilio credentials, so `SMS_PROVIDER` defaults to `fake`
(`Gateways::FakeSmsGateway`), which logs only send metadata (never the raw
message body) and returns a synthetic success SID without any network call —
the full send/list flow is demonstrable end-to-end without real SMS
delivery.

`Gateways::TwilioSmsGateway` is **implemented but unverified — needs live
credentials from the client.** It is fully wired behind
`Services::Container` (config-only swap via `SMS_PROVIDER=twilio`, no code
changes) and reads `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` /
`TWILIO_FROM_NUMBER` from ENV only — never hardcoded, never logged.
`config/initializers/container.rb` fails loudly at boot (a clear
`ArgumentError` naming the missing var(s)) if `SMS_PROVIDER=twilio` is set
without all three credentials present, rather than deferring the failure to
the first real send attempt. It has **not been tested against the live
Twilio API** in this pass (no creds available) — see `doc/tech-design.md` §4.2
and the risk noted in `doc/HLD.md` §9. Once the client supplies credentials,
set them plus `SMS_PROVIDER=twilio` and restart — no code changes required.

Rate limiting (`rack-attack`, `config/initializers/rack_attack.rb`) throttles
`POST /api/v1/messages` to 10 requests/minute per identity before any real
Twilio credentials go live, to bound cost-abuse risk.

## Repository layout

```
MySMS-Messenger/
├── doc/            # HLD.md, tech-design.md
├── backend/        # Rails 7.1 API-only app
├── frontend/       # Angular standalone SPA
├── docker-compose.yml
└── .env.example
```

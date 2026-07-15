# QA + Security Review — Bonus 2: Deployment (originally Fly.io)

> **Note (2026-07-15): the deploy target was switched from Fly.io to
> Render** after this review was written (Fly.io now requires a credit
> card with no meaningful free tier; Render's free Web Service + Static
> Site instances are genuinely $0/month, no card required). The `fly.toml`
> files this review examined have been deleted and replaced by a
> repo-root `render.yaml` Blueprint; `frontend/Dockerfile`/`nginx.conf` were
> also removed since Render's Static Site service needs neither. **The
> substance of every finding below still applies** — the force_ssl/health-
> check redirect bug, the CORS silent-fallback fix, the rack-attack
> per-process-store caveat, and the missing-`Gemfile.lock` trade-off are
> all provider-agnostic and remain true on Render. Only the specific
> file/command names below (`fly.toml`, `fly secrets set`, etc.) are
> superseded — see `doc/tech-design.md` §14 for the current Render-specific
> config.

Scope (as originally reviewed): `doc/tech-design.md` §14 (locked design) vs.
the actual committed files: `backend/Dockerfile`, `backend/fly.toml`,
`backend/config/environments/production.rb`,
`backend/config/initializers/cors.rb`,
`backend/app/controllers/concerns/current_identity.rb`,
`frontend/Dockerfile`, `frontend/nginx.conf`, `frontend/fly.toml`,
`frontend/src/environments/environment.production.ts`, `.env.example`,
`docker-compose.yml`. Read-only review; no code changed.

## Top-line verdict

**CP19–CP21 artifacts are internally consistent and match the locked §14
design.** No secrets are baked into any image layer or committed in
plaintext. The force_ssl/health-check fix is correctly implemented for the
actual route path. The Gemfile.lock removal is handled consistently (no
stale references). One genuine **High** gap exists (`CORS_ORIGINS` silent
localhost fallback) and one **Major/Medium** known caveat is carried forward
unaddressed (Rack::Attack `MemoryStore` vs. multi-machine scaling). Neither
blocks a first deploy attempt with `min_machines_running = 0` and a single
machine, but both should be fixed/acknowledged explicitly before the
director scales beyond one instance or before calling this "prod-hardened."

---

## Security findings

### High

**H1 — `CORS_ORIGINS` has a hardcoded `localhost:4200` fallback that fails silently in production, unlike every other required prod value.**
`backend/config/initializers/cors.rb`:
```ruby
origins ENV.fetch("CORS_ORIGINS", "http://localhost:4200").split(",")
```
`SECRET_KEY_BASE` and `MONGO_URI` both use `ENV.fetch(...)` **with no
default**, so a forgotten secret fails loudly at boot (crash, visible in Fly
logs, fixable immediately). `CORS_ORIGINS` is the one prod-required value
that instead silently degrades to a useless dev default if the director
forgets `fly secrets set CORS_ORIGINS=...`. The API boots fine, `/health`
returns 200, the deploy looks green — but every real cross-origin request
from `mysms-messenger-web.fly.dev` gets rejected by the browser's CORS
preflight with an opaque network error, no server-side error to grep for.
This is exactly the "confusing silent breakage" chaos scenario in the
instructions, and it is objectively worse than the other two secrets
because there's no fail-fast signal. `tech-design.md` §14.2 acknowledges
CORS_ORIGINS is "not truly secret" and lets it live in `[env]` or secrets,
but doesn't call out that the fallback default should be removed for
production. **Recommendation:** drop the default in production (e.g.
`Rails.env.production? ? ENV.fetch("CORS_ORIGINS") : ENV.fetch("CORS_ORIGINS", "http://localhost:4200")`)
so a missing value crashes at boot like the other two secrets, rather than
silently serving a config that can never match a real origin.

### Medium

**M1 — Rack::Attack still uses the default in-process `MemoryStore`; this is a real scaling caveat for this specific deployment, not just theoretical.**
Confirmed no `Rack::Attack.cache.store =` line anywhere in
`backend/config/initializers/rack_attack.rb`, and no `config.cache_store`
override in `production.rb` — this reconfirms the finding already tracked in
`doc/code-review-iteration-1.md` (MIN5) and `doc/qa-report-round2.md`: the
throttle counters are per-OS-process. `backend/fly.toml` sets
`min_machines_running = 0` (scale-to-zero, single machine on demand), so
**today this is not exploitable** — there's normally only one machine (or
zero). But Fly's `auto_start_machines`/autoscaling model means a burst of
traffic can spin up more than one machine concurrently, and nothing in
`fly.toml` caps `max` at 1. If the director later bumps
`min_machines_running` above 0 or Fly autoscales up during a traffic spike,
each machine gets its own independent 10-req/60s and 5-req/60s counters,
silently multiplying the effective throttle by the machine count — directly
undermining the H1 cost-abuse protection this rate limiter exists for
(`rack_attack.rb`'s own comment: "the only thing standing between this code
and unbounded spend" once Twilio creds are live). Not a regression
introduced by Bonus 2, but Bonus 2 is the first place a real multi-machine
deploy is actually possible, so it should be called out in the fly.toml
runbook/comments now rather than left implicit. **Recommendation:** either
pin `max_machines_running = 1` for now (documented tradeoff), or switch
`Rack::Attack.cache.store` to a shared backend (e.g. Redis) before scaling
past one machine — flag this explicitly in §14 rather than leaving it only
in older review docs.

### Low

**L1 — Atlas `0.0.0.0/0` network allow-list is a deliberate, already-flagged tradeoff (§14.7 item 3), not a new issue.** Confirmed the doc's own
reasoning (password-gated via `MONGO_URI`, no static Fly egress IP
available on the free tier) is sound and already labeled demo-only. No
action needed beyond what's already documented.

**L2 — `apiBaseUrl` committed as a real-looking URL that is actually a placeholder.** `frontend/src/environments/environment.production.ts` ships
`apiBaseUrl: 'https://mysms-messenger-api.fly.dev'` — this is syntactically
valid and will build/deploy without any error, but it is a placeholder that
only happens to be correct if the director uses the exact app name
`mysms-messenger-api`. This is the intended, reviewed design (§14.5,
"Chosen approach... commit the real API URL"), so not a defect, but worth
restating as QA-visible: nothing in the build pipeline validates that this
hostname actually resolves to a live Fly app before `npm run build` bakes
it in. See QA finding Q-C1 below for the chaos-mode consequence.

### Informational

**I1 — Secrets-vs-`[env]` split matches what actually needs to be secret.**
`backend/fly.toml`'s `[env]` block contains only `RAILS_ENV`,
`MESSAGE_REPOSITORY`, `SMS_PROVIDER`, `CROSS_ORIGIN_COOKIES`,
`RAILS_LOG_TO_STDOUT`, `PORT` — all genuinely non-secret. `SECRET_KEY_BASE`
and `MONGO_URI` appear nowhere in any committed file except as
comment-documented `fly secrets set ...` commands with placeholder
`USER:PASS`/`$(bin/rails secret)` — no real value is ever committed. No
Twilio creds present anywhere (`SMS_PROVIDER=fake`, `TWILIO_*` blank in
`.env.example`). `docker-compose.yml` only stands up local Mongo with no
credentials embedded. Dockerfiles contain no `ARG`/`ENV` secret injection at
all. **Clean.**

**I2 — `CROSS_ORIGIN_COOKIES=true` is present in `backend/fly.toml`'s `[env]` block** (line: `CROSS_ORIGIN_COOKIES = "true"`), matching §14.6's
requirement exactly. This is not a gap — confirmed present and correctly
wired to `current_identity.rb`'s `cross_origin_cookies?` check, which also
correctly forces `secure: true` whenever cross-origin mode is on
(browsers reject `SameSite=None` without `Secure`). No finding here.

---

## QA / correctness findings

### Blocker

None found. Nothing here would prevent a build or a first deploy attempt
from at least starting.

### Major

**Q-M1 — Same issue as security H1, restated from a build-correctness angle: `CORS_ORIGINS` fallback means a "successful" deploy can still be completely unusable end-to-end**, with the failure surfacing only in the
browser console (CORS error) on the very first login attempt, not in `fly
logs` for the API. QA/demo-day risk: this is the kind of failure that eats
a live-demo timeslot because the API looks perfectly healthy the whole
time.

### Minor

**Q-N1 — Dockerfile/Gemfile.lock fix is internally consistent; no leftover references found.** Checked the full `backend/Dockerfile` for any
remaining `Gemfile.lock` reference after the `BUNDLE_DEPLOYMENT=1` removal:
`COPY Gemfile ./` (no `Gemfile.lock` in the COPY list), no
`BUNDLE_DEPLOYMENT` in either stage's `ENV` block, `bundle install` runs
unconstrained (resolves + writes its own lock at build time, per the
Dockerfile's own comment). Confirmed no `Gemfile.lock` file exists in
`backend/` at all. This is consistent and correctly reasoned — the fix is
real, not cosmetic. The documented tradeoff (non-reproducible resolution
across builds until a real lock file is generated with registry access) is
accurately described and not silently swept under the rug.

**Q-N2 — force_ssl/health-check fix targets the correct, actual route.**
Verified `config/routes.rb`: `get "/health", to: "api/v1/health#show"` is
mounted at the bare top-level path `/health` (not under the
`namespace :api do namespace :v1` block that wraps `messages`/`auth`), so
`production.rb`'s `request.path == "/health"` exact-match in
`config.ssl_options[:redirect][:exclude]` is correct — it matches the real
request path, not `/api/v1/health` as the controller's file location might
suggest. The `->(request) { ... }` lambda form is the correct Rails 7.1 API
for `config.ssl_options[:redirect][:exclude]` (takes a `Rack::Request`-like
object, tested via `request.path`). Confirmed `silence_healthcheck_path`
and `ssl_options` are two independent settings as the code comment states —
no overlap, no double-counting, and the exclude lambda only matches the
exact `/health` string so no other path is accidentally exempted from the
SSL redirect/HSTS. This is a correct, narrowly-scoped fix.

**Q-N3 — Dockerfile multi-stage copy is minimal and correct.** Final stage
copies only `/usr/local/bundle` (installed gems) and `/app` (app code +
precompiled bootsnap cache) from `build`; no `build-essential`/compiler
toolchain, no apt cache, no extra layers. `USER app` is set after
`chown -R app:app /app`, and the final `CMD` runs as that non-root user, not
root. Binds `0.0.0.0`, honors `${PORT:-8080}`, matches `internal_port =
8080` in `fly.toml`. No discrepancies from §14.1.

**Q-N4 — nginx listens on the port fly.toml expects and won't 404 the SPA.** `frontend/nginx.conf` `listen 8080` matches
`frontend/fly.toml`'s `internal_port = 8080` and `frontend/Dockerfile`'s
`EXPOSE 8080`. `location / { try_files $uri $uri/ /index.html; }` correctly
falls back to `index.html` for any unknown path (Angular deep links won't
404). The hashed-asset regex block uses `try_files $uri =404`, which is
correct and intentional (a genuinely missing hashed asset should 404, not
silently serve `index.html` as HTML). Build path
`dist/frontend/browser` matches the note in §14.3 about the
`@angular/build:application` builder's mandatory `browser/` subfolder. No
startup-blocking misconfiguration found.

### Nitpick

**Q-Nit1 — `frontend/fly.toml`'s health check hits `/` (not a dedicated `/healthz`), which is fine for a static SPA but means "200" only proves nginx is up, not that any specific asset is present.** Purely
informational; not a real risk for a pure static file server with an
`index.html` guaranteed by the build.

---

## Chaos-mode answers (explicit, per the assignment's 3 scenarios)

**Q-C1 — Cold start (scale-to-zero, `min_machines_running = 0`) — does the health check tolerate a slow first boot?**
Yes, with a caveat. `[[http_service.checks]]` sets `grace_period = "10s"`
before the first check counts against the machine, and `interval = "15s"` /
`timeout = "2s"` afterward. Rails + bootsnap-precompiled boot on a `ruby:3.3-slim`
image is normally well under 10s, so this should tolerate the real cold
start. The caveat: this grace period is untested against the actual Mongoid
driver's connection-establishment time to Atlas on a cold machine (DNS SRV
lookup + TLS handshake to a different cloud region) — if that takes several
seconds beyond Rails' own boot, 10s could be tight. Not a defect, but an
untested assumption worth a live smoke test at CP22.

**Q-C2 — `MONGO_URI` wrong/unreachable — fail loudly or hang/crash confusingly?**
Partially loud, partially not. If `MONGO_URI` is **unset**,
`mongoid.yml`'s `ENV.fetch("MONGO_URI")` (no default in the `production:`
block) raises immediately at Rails boot — loud, correct, matches
`SECRET_KEY_BASE`'s pattern. If `MONGO_URI` is **set but wrong/unreachable**
(bad password, wrong cluster host, Atlas allow-list not yet applied),
Mongoid's driver does **not** fail at boot — Mongo drivers connect lazily on
first query. The app will boot fine, `/health` returns 200 (it doesn't
touch Mongo), and the **first real request that touches the DB** (signup,
login, send, history) will hang for the driver's server-selection timeout
(Mongoid/Mongo Ruby driver default ~30s) before surfacing a
`Mongo::Error::NoServerAvailable` as an unhandled 500. This is a
genuine "looks healthy, isn't" scenario: Fly's health check passes, but the
app is unusable. Worth flagging as an operational gap — not something this
review recommends blocking on, but the director should know that a green
Fly deploy does not confirm Mongo connectivity; only a real end-to-end
signup/login test does (per §14.8 CP22's own acceptance criteria, which
already requires this).

**Q-C3 — Frontend deployed before the backend exists (`apiBaseUrl` points at a 404/non-existent host) — graceful degradation or silent breakage?**
Silent-ish breakage, but not silently wrong-looking to an attentive
tester: the SPA itself loads fine (nginx serves static files
unconditionally, independent of the API's existence), and the app's shell
renders. But every API call (`MessagesApiService`, auth calls) hits a
hostname that either doesn't resolve (before the API app is created on Fly)
or, after `fly apps create` runs but before `fly deploy`, returns Fly's
generic "app isn't running" placeholder page — in both cases the browser
network tab shows a clear failure. This wasn't reviewed for a specific
user-facing error state as part of this pass (no frontend error-handling
files were in the reviewed set), so we can't confirm whether the user sees
a friendly message or a blank/broken screen — flagged as an open question,
not a confirmed defect, and mitigated procedurally anyway by §14.8 CP22
correctly sequencing "API app first, so its hostname is known before the
web image is built."

---

## Summary table

| # | Severity | Finding |
|---|----------|---------|
| H1 / Q-M1 | High / Major | `CORS_ORIGINS` silently falls back to `localhost:4200` in prod if the secret is forgotten — no fail-fast, unlike `SECRET_KEY_BASE`/`MONGO_URI` |
| M1 | Medium | Rack::Attack `MemoryStore` is per-machine; not exploitable today at `min_machines_running=0`, but not capped against future multi-machine scaling either |
| L1 | Low | Atlas `0.0.0.0/0` — already flagged/accepted tradeoff, confirmed sound |
| L2 | Low | `apiBaseUrl` is a working-looking placeholder, by design, per §14.5 |
| Q-N1–N4 | Minor | Dockerfile/Gemfile.lock consistency, force_ssl exclude correctness, multi-stage copy hygiene, nginx port/SPA fallback — all verified correct |
| Q-C1–C3 | Chaos | Cold start likely fine (untested Atlas-latency assumption); bad `MONGO_URI` hangs on first real request rather than failing at boot; frontend-before-backend degrades to visible network errors, not silent corruption |

**Overall: ready for a first `fly deploy` attempt at CP22 as currently
written**, provided the director treats H1/Q-M1 as a pre-flight checklist
item (verify `CORS_ORIGINS` is actually set, don't just trust a green
health check) and is aware of M1's scaling caveat before increasing
`min_machines_running` beyond the current single-machine posture.

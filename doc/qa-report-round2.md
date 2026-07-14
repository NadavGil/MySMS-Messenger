# MySMS Messenger — QA / Chaos Engineering Report, Round 2 (Fix Verification)

**Reviewer:** QA & Chaos Engineer
**Scope:** Verification of the 8 round-1 findings against fix commits
`5ae5619`, `05a3ac6`, `28e85ba`, CP11-related backend work, `1b26cc2`,
`baa8e07` (frontend), `8e044aa` (docs). Also a fresh chaos pass on the
current, more mature codebase to look for issues the fixes themselves may
have introduced.
**Method:** Read the actual current source (not commit messages) under
`backend/app`, `backend/config`, `backend/spec`, `frontend/src`, root
`.env.example`, `docker-compose.yml`. No code was modified.

---

## Verdict summary — round-1 findings

| # | Finding | Verdict |
|---|---|---|
| 1 | Blocker: Container repository singleton/memoization | **VERIFIED-FIXED** |
| 2 | High: rack-attack throttling on `POST /api/v1/messages` | **VERIFIED-FIXED** |
| 3 | Medium: `CurrentIdentity` SameSite/Secure env-driven behavior | **VERIFIED-FIXED** |
| 4 | Medium: `FakeSmsGateway` logging raw body | **VERIFIED-FIXED** |
| 5 | Major: Mongo error handling in `MongoMessageRepository` | **VERIFIED-FIXED** |
| 6 | Major: double `/api` prefix (frontend) | **VERIFIED-FIXED** |
| 7 | Minor: codepoint-based char counting | **VERIFIED-FIXED** |
| 8 | Minor: `MessagesStoreService.refresh()` race | **VERIFIED-FIXED** |

**8/8 verified-fixed.** No partial or unfixed items. Details below, followed
by new issues surfaced by this round's fresh chaos pass.

---

### 1. Container singleton (Blocker B1) — VERIFIED-FIXED
`backend/app/services/container.rb` now memoizes
`@in_memory_message_repository ||= klass.new` only for
`Repositories::InMemoryMessageRepository` (correctly leaves
`MongoMessageRepository` unmemoized since it's stateless). A `reset!` method
clears the memo, and `backend/spec/rails_helper.rb` calls
`Services::Container.reset!` in a `before(:each)`, giving proper test
isolation. `container_spec.rb` now has explicit regression tests: "memoizes a
single shared in_memory repository instance across calls" (`equal` check)
and "`#reset!` clears the memoized in_memory repository." This closes both
the original defect and the spec gap the round-1 report called out.

### 2. rack-attack throttling — VERIFIED-FIXED
`gem "rack-attack"` is in `backend/Gemfile`; `backend/config/initializers/rack_attack.rb`
defines a `throttle("messages/send/owner_id", limit: 10, period: 60)` scoped
to `req.post? && req.path == "/api/v1/messages"`, keyed on the signed
`msms_owner` cookie (falls back to `req.ip` when absent/invalid), disabled in
test env and via `RACK_ATTACK_DISABLED` (documented in root `.env.example`).
`throttled_responder` returns the project's standard `{errors: {base: [...]}}`
JSON shape with 429. This is correctly wired — `Rack::Attack` is a Rack
middleware auto-inserted by the gem into `Rails.application.config.middleware`
once required, so no separate middleware-stack registration was needed or
missing. No dedicated request spec exercises the throttle itself (see New
Issues below), but the logic as written is sound.

### 3. `CurrentIdentity` SameSite/Secure env-driven behavior — VERIFIED-FIXED
`backend/app/controllers/concerns/current_identity.rb` now derives
`same_site_policy` and `secure_cookie?` from a single `CROSS_ORIGIN_COOKIES`
env flag: `:none`+`secure:true` when set, else the previous `:lax` +
`Rails.env.production?` behavior. This is logically sound — `SameSite=None`
is always paired with `Secure` (satisfies the browser requirement), and
same-origin/dev deployments keep working with zero extra config. Documented
in root `.env.example` and README per commit `8e044aa`. Matches round-1 M1's
recommendation exactly.

### 4. `FakeSmsGateway` no longer logs raw body — VERIFIED-FIXED
`backend/app/gateways/fake_sms_gateway.rb`'s `log_send` now logs
`body_length=#{body.to_s.length}` instead of the raw body; `to` (phone
number) and `success`/`external_sid` are still logged, which is an
acknowledged, reasonable trade-off (phone number retained for debugging,
matching the original review's framing). `TwilioSmsGateway` still logs
nothing content-related.

### 5. Mongo error handling — VERIFIED-FIXED
`backend/app/repositories/mongo_message_repository.rb` now defines
`Repositories::RepositoryError` and rescues `Mongo::Error` in both `create`
and `find_for_owner`, logging the real driver exception server-side and
raising the structured `RepositoryError` instead. Crucially, this is also
wired all the way to the HTTP boundary:
`backend/app/controllers/application_controller.rb` has
`rescue_from Repositories::RepositoryError` rendering
`{errors: {base: [...]}}` with `status: :service_unavailable` (503) — so a
Mongo outage now surfaces as the documented structured-error shape, not an
unhandled 500/backtrace leak. This fully closes N3, including the follow-on
question (not explicit in N3) of what the service/controller layer does with
the raised error.

### 6. Double `/api` prefix — VERIFIED-FIXED, no regressions found
All three environment files were checked:
- `environment.ts` / `environment.development.ts`: `apiBaseUrl: 'http://localhost:3000'` (full origin, no `/api` segment).
- `environment.production.ts`: `apiBaseUrl: ''` (same-origin/reverse-proxy convention), with a clear comment on how to set it for a cross-origin deploy.
`messages-api.service.ts` builds `baseUrl` as
`` `${environment.apiBaseUrl}/api/v1/messages` `` in exactly one place, so all
three environments now compose to `/api/v1/messages` correctly with no
double-prefix path possible under the new convention. No other file
constructs a request URL independently (`messages-store.service.ts` and
components all go through `MessagesApiService`), so there's no
regression risk from a second hard-coded path elsewhere.

### 7. Codepoint-based char counting — VERIFIED-FIXED, consistent everywhere
`frontend/src/app/utils/text-length.util.ts` exports `codepointLength`
(`Array.from(text).length`) and `maxCodepointLength` (a `ValidatorFn`
producing the same `{maxlength: {requiredLength, actualLength}}` shape as
Angular's built-in validator). Verified consistent use in all four places
that need it:
- `new-message.component.ts` form validator (`maxCodepointLength(250)`) and the live `bodyLength` getter (both codepoint-based).
- `new-message.component.html` deliberately omits the native `[maxlength]` attribute (which truncates by UTF-16 code unit) with an explicit comment explaining why, relying on the validator + disabled Submit instead — this preserves the 250-limit UX (Submit disables, counter shows true count) without a conflicting truncation behavior.
- `message-history.component.ts`'s `bodyLength()` also calls `codepointLength`, so the per-message history counter agrees with the form counter.
- Backend `backend/app/services/send_message_service.rb` validates via Ruby's `body.length > MAX_BODY_LENGTH` (`MAX_BODY_LENGTH = 250`), and Ruby `String#length` counts Unicode codepoints — matching the frontend's `Array.from(text).length` convention. Frontend and backend now agree on the same unit.
A `grep` for other `.length` usages in the frontend tree found no stray
UTF-16-based counts left in message-related code (the two other `.length`
hits are `messages$.length` array-size and an `?.length === 0` empty-list
check, both unrelated to character counting).

### 8. `MessagesStoreService.refresh()` race — VERIFIED-FIXED, no leaks/broken subscriptions
`messages-store.service.ts` was restructured around a `refreshTrigger$`
`Subject` piped through `switchMap` into a **single, permanent** internal
subscription created once in the constructor. `refresh()` now just calls
`refreshTrigger$.next()` rather than starting a fresh one-off `.subscribe()`.
This is architecturally the right shape for the specific worry raised in the
task (does `switchMap` cancel a request some component's own subscription is
still waiting on?) — no, because components never subscribe to the
`listMessages()` call itself; they only observe the store's long-lived
`messages$`/`loading$`/`error$` `BehaviorSubject`s via the `async` pipe
(confirmed in `message-history.component.ts`). `loadingSubject.next(true)`
fires before the switched-to inner observable starts, and both `tap`
(success) and `catchError` (failure) branches inside the `switchMap` project
set `loadingSubject.next(false)` — so even when an older inner request is
cancelled by a newer `refresh()`, the *newer* request's own completion
always flips loading back to false; there is no code path where a
component would see `loading$` stuck `true` forever, because the outer
subscription is never torn down and every `refresh()` guarantees a new
inner observable will (eventually) resolve one of the two branches. No
memory leak: the outer `.subscribe()` is intentionally never unsubscribed
(the service is `providedIn: 'root'`, a singleton for the app's lifetime,
so this is the correct, standard "persistent store" pattern, not a leak).
`messages-store.service.spec.ts` has a dedicated regression test
("does not let a stale, slower refresh() response overwrite a newer one")
that asserts `firstReq.cancelled` is `true` via `HttpClientTestingModule` —
directly exercising the fix.

---

## New issues from this round's fresh chaos pass

None of these are regressions that break the 8 confirmed fixes above; they
are new considerations the fixes themselves surface now that the codebase is
more mature (CP11 Twilio wiring, real deploy topology decisions ahead).

### Major

**NEW-1. Rack::Attack's default cache store is process-local — the 10/60
limit does not hold across multiple Puma workers/dynos.**
No `Rack::Attack.cache.store` is configured anywhere in
`backend/config/initializers/rack_attack.rb`, so it defaults to
`ActiveSupport::Cache::MemoryStore`, which is per-OS-process. There is also
no `backend/config/puma.rb` in this repo (checked — not present), so today's
default Puma config is effectively single-process/single-worker, which
happens to make the current limit correct by accident. The moment this app
is deployed with `WEB_CONCURRENCY > 1` (multiple Puma worker processes) or
horizontally scaled across multiple containers/dynos — a very plausible
step once real Twilio credentials and real traffic show up — each process
keeps its own independent counter, so the effective throttle becomes
`10 * (worker_count * instance_count)` per owner_id/IP per 60s, silently
defeating the cost-abuse protection this fix exists for. Recommend a shared
store (e.g. `Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(...)`)
before any multi-process/multi-instance deployment, and a comment/README
note flagging this constraint now so it isn't forgotten when CP11's Twilio
path goes live for real.

### Minor

**NEW-2. No request-spec coverage for the rack-attack throttle itself.**
`backend/spec` has no spec exercising `Rack::Attack` directly (confirmed —
no file matching `*rack*` under `backend/spec`, and `messages_controller_spec.rb`
has no throttle/429 assertions). The throttle is disabled in test env
(`Rails.env.test?` guard), which is reasonable for not slowing down the rest
of the suite, but means there is currently zero automated coverage that the
throttle key logic (owner_id vs. IP fallback), the limit/period values, or
the 429 JSON shape actually behave as designed — regressions here would only
be caught by manual/production testing. Recommend a narrow spec that
force-enables Rack::Attack (e.g. via `Rack::Attack.enabled = true` in an
example-scoped `before`/`after`) and asserts the 11th rapid POST from the
same owner_id gets a 429 with the documented error shape.

**NEW-3. `InMemoryMessageRepository`'s single `Mutex` serializes all reads
and writes process-wide, but this is very unlikely to matter at this app's
scale — noted as a design trade-off, not a defect.**
`create` and `find_for_owner` both take the same `@mutex`. Critical sections
are short (array push, or select+sort+reverse over an in-process array), so
lock hold time is minimal and there is no nested-locking / re-entrancy path
in this class (no method calls `@mutex.synchronize` inside another
`synchronize` block), so there is **no deadlock risk**. Under heavy
concurrent load this would fully serialize all in-memory-mode traffic (a
GET blocks behind a concurrent POST's lock and vice versa), which is a real
throughput ceiling — but `MESSAGE_REPOSITORY=in_memory` is explicitly the
"fast demo" mode, not the production path (`MongoMessageRepository` has no
such serialization), so this is an acceptable trade-off rather than a bug.
Flagging only so nobody mistakes the demo mode's throughput characteristics
for the real (Mongo-backed) production path's.

### Nitpick

**NEW-4. `FakeSmsGateway.log_send` still logs the destination phone number
at `info` level.**
Carried over from the original M5 discussion (security-review-round1.md
explicitly considered and deferred this): `to=#{to}` remains in the log
line. This was intentionally kept for debugging per the round-1 write-up's
own framing, so not re-flagging as a defect — just confirming it wasn't
silently dropped as an unintended side effect of the body-logging fix, and
that phone numbers are still worth a policy decision if PII rules tighten.

**NEW-5. Cross-origin cookie mode (`CROSS_ORIGIN_COOKIES=true`) has no
automated test coverage.**
`current_identity_spec.rb` was not observed to include an example that sets
`CROSS_ORIGIN_COOKIES=true` and asserts `SameSite=None; Secure` is actually
set on the response cookie. The logic reads correctly by inspection (see
item 3 above), but as with NEW-2, this env-gated branch currently has no
regression test protecting it from being silently broken by a future
refactor of `CurrentIdentity`.

---

## Overall recommendation

All 8 round-1 findings are genuinely fixed in the current code, with good
in-line documentation tracing each fix back to its originating finding and,
notably, new regression tests added specifically to catch each defect
mechanically (container singleton, stale-refresh cancellation). This is a
mature, well-verified fix pass — no blockers or majors from round 1 remain
open.

The one new **Major** (NEW-1, Rack::Attack's process-local cache store) is
worth a quick fix or at minimum a documented flag before real Twilio
credentials and any multi-process/multi-instance deployment go live, since
it directly undermines the cost-abuse protection that was this round's
highest-priority security fix. It does not block moving to final
system-wide code review, but should be tracked as a follow-up alongside
CP11's production rollout checklist.

**Ready to proceed to final system-wide code review**, with NEW-1 flagged
as a pre-production follow-up item and NEW-2/NEW-5 as test-coverage debt.

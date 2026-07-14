# MySMS Messenger — Security Review, Round 1

| | |
|---|---|
| **Reviewer** | Security Specialist |
| **Scope** | Backend CP1 (Rails skeleton), CP2 (Mongo DAL/models), CP3 (`Services::Container` IoC), CP5 (`CurrentIdentity`); Frontend CP8–CP10 (Angular skeleton, `NewMessageComponent`/`MessagesApiService`, `MessageHistoryComponent`) |
| **Method** | Static review of committed source only (read-only; no code changed) |
| **Not yet built** | None remaining in the originally-scoped checkpoint set — CP1–CP12 all landed during this review window. |

> **Addendum:** This review began against CP1/CP2/CP3/CP5/CP8–CP10 only, per the assigned scope. While the review was in progress, the rest of the team concurrently landed CP4 (`Gateways::FakeSmsGateway`/`Gateways::TwilioSmsGateway`), CP6 (`Api::V1::MessagesController#create` + `Services::SendMessageService`), CP7 (`Services::ListMessagesService` + `MessagesController#index`), and **CP12 (`config/initializers/cors.rb`, `docker-compose.yml`, root `.env.example`)**. Findings **H1, L1, L3, and I1** below were updated in place to reflect the real, now-committed code rather than "not yet built" — this is noted so the reader understands why some findings read differently than a review strictly scoped to the original checkpoint list would.

---

## Summary of findings

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 1 |
| Medium | 5 |
| Low | 3 |
| Informational | 6 |

---

## High

### H1. No rate limiting on the send-SMS endpoint — real cost/abuse exposure
Confirmed: no `rack-attack` or equivalent gem in `backend/Gemfile`, and `POST /api/v1/messages` (`backend/app/controllers/api/v1/messages_controller.rb`, now implemented) has no throttling anywhere in front of it — the container/service/gateway chain runs unconditionally on every request that passes basic E.164/length validation. Because sending real SMS via Twilio costs money per message, and the only "auth" is a self-issued signed cookie (see M1/I4 below), a client can mint unlimited identities (clear cookies / new browser / curl without cookies) and hammer the send endpoint the moment `SMS_PROVIDER=twilio` is set with real credentials. This is called out in the HLD itself (§9 Risks) as deferred, so it is not a bug in delivered code — but it must be treated as a **must-fix-before-real-Twilio-credentials-are-configured** item, not a nice-to-have, since today's default (`SMS_PROVIDER=fake`, per `.env.example`) is the only thing standing between the current code and unbounded real-money spend.
- **Recommendation:** add `rack-attack` (or equivalent) keyed on `owner_id`/IP before CP11 (real Twilio gateway activation) in any environment reachable by untrusted traffic. This is the single most important action item from this review.

---

## Medium

### M1. `owner_id` cookie is a bare identity token with no server-side session store / revocation
`CurrentIdentity` (`backend/app/controllers/concerns/current_identity.rb`) issues a `SecureRandom.uuid` wrapped in `cookies.signed`. This is tamper-evident (Rails' signed cookie uses `secret_key_base` HMAC) so a client cannot forge or guess another user's `owner_id` by guessing — this is good and matches HLD §7.3. However:
- There is no way to invalidate/rotate a leaked identity (no server-side session table); if a cookie is exfiltrated (e.g., via XSS on some future page, or physical device access), it is valid for `1.year.from_now` with no revocation mechanism.
- This is an accepted trade-off for a cookie-only "session ID = identity" design (no login in this pass, per HLD), so it's Medium rather than High, but should be revisited when Bonus 1 (auth) lands.

### M2. Cookie `secure` flag is keyed off `Rails.env.production?`, not off the actual scheme of the request
`secure: Rails.env.production?` in `current_identity.rb` means any non-"production" `RAILS_ENV` (e.g., a staging env that is nonetheless served over HTTPS behind a real domain, or a demo env) will get `secure: false`, allowing the cookie to be sent over plaintext HTTP. Recommend keying off `request.ssl?` or an explicit `FORCE_SECURE_COOKIES` env var instead of the Rails environment name, so any TLS-terminated deployment gets `Secure` regardless of `RAILS_ENV` value.

### M3. `SameSite=Lax` may silently break the documented CORS + credentials flow, or be weaker than needed depending on deployment topology
Tech-design.md's CORS section (§2.10) assumes the Angular SPA and Rails API are on different origins (`http://localhost:4200` → `http://localhost:3000`) with `withCredentials: true` / `credentials: true`. **`SameSite=Lax` cookies are not sent on cross-site XHR/fetch requests initiated by JavaScript** in most browsers (`Lax` mainly permits top-level navigation GETs). If the SPA and API remain on different origins/ports in any deployed environment (not just localhost, where dev-tooling often relaxes this), the browser will refuse to attach the `msms_owner` cookie to the API calls, breaking identity continuity silently (each request would look like a "new" identity, or none at all).
- If cross-origin deployment is intended (per HLD Bonus 2 / CP12), this cookie should be `SameSite=None; Secure` (which requires HTTPS everywhere, including local dev — usually solved by proxying the SPA through the API's origin instead). Flag for the CP12 implementer to decide the actual deployment topology and adjust `same_site` accordingly — current `:lax` looks like it was chosen defensively but may not function as intended once cross-origin.

### M5. `FakeSmsGateway` logs the full, unredacted message body to `Rails.logger`
`backend/app/gateways/fake_sms_gateway.rb`: `Rails.logger.info("[FakeSmsGateway] to=#{to} body=#{body.inspect}")` writes the destination phone number and the **entire user-supplied message text** to the application log on every send, at `info` level, in every environment where the fake gateway is active (dev, test, and — per `config/initializers/container.rb` — any environment that hasn't explicitly set `SMS_PROVIDER=twilio`, which today is every environment by default). Message bodies are arbitrary free text the end user typed, which can carry PII or sensitive content; writing it verbatim to logs is an avoidable info-disclosure/compliance risk (logs are often shipped to third-party aggregators, retained indefinitely, or accessible to a wider ops audience than the app itself). `TwilioSmsGateway` does **not** have this problem — it performs no such logging.
- **Recommendation:** either drop the `body` from the log line entirely, or log only its length (`body=#{body.length} chars`) as `MessageDocument`/`Domain::Message` already do conceptually for the char-count UI. Keep `to` if useful for debugging, but reconsider even that if phone numbers are considered PII under the client's data-handling policy.

### M4. `.gitignore` does not explicitly exclude Rails credentials/master key files
Root `.gitignore` ignores `backend/log/*`, `backend/tmp/*`, `backend/.bundle/`, `backend/vendor/bundle/`, `*.gem`, `.env`, `*.env.local`, OS files — but has **no entry for `backend/config/master.key`** or `backend/config/credentials/*.key`. No such files exist in the repo today (verified — none found), so there is no live leak, but if a future dev runs `rails credentials:edit` and generates `config/master.key`, the current `.gitignore` will not catch it before a commit. Recommend adding `backend/config/master.key` (Rails' own generator normally adds this automatically to a per-app `.gitignore`, but this repo uses a single hand-rolled root `.gitignore`, so it was missed).

---

## Low

### L1. No NoSQL injection surface — confirmed against the now-committed controller
`MongoMessageRepository#find_for_owner` (`backend/app/repositories/mongo_message_repository.rb`) builds its Mongoid query as `MessageDocument.where(owner_id: owner_id)` — a plain string value, not a raw hash/operator fragment from user input. `Api::V1::MessagesController#create` (now committed) passes `owner_id: current_identity`, which is the server-generated signed-cookie identity, never a client-supplied param — so there is no path for a client to inject a Mongo operator (e.g. `{"$where" => ...}`) into the scoping query. `to_number`/`body` from `params[:to_number]`/`params[:body]` are read as individual scalars (not `params.permit!` / hash blobs) and are passed straight through as `String` field values to `MessageDocument.create!`, not merged into any `where`/operator clause — safe. No NoSQL injection found in the code as committed.

### L2. XSS: current Angular templates are safe by default, but there is no explicit test/lint guard against future regressions
Reviewed `message-history.component.html` and `new-message.component.html`: message bodies and phone numbers are rendered exclusively via Angular interpolation (`{{ message.body }}`, `{{ message.to_number }}`), which Angular auto-escapes (contextual output encoding). **No `[innerHTML]`, `bypassSecurityTrust*`, or `DomSanitizer` usage anywhere in the frontend tree** (confirmed via full-tree read of all `.ts`/`.html` files) — this is the correct, safe default and there is no live XSS today. Flagged Low only as a process recommendation: add an ESLint rule (e.g. `@angular-eslint` `no-inner-html` or similar) so a future dev cannot introduce `[innerHTML]` binding of the (user-supplied) message `body` field without a deliberate sanitizer review.

### L3. Strong-params / mass-assignment — confirmed safe, but no explicit param whitelisting
`Api::V1::MessagesController#create` (`backend/app/controllers/api/v1/messages_controller.rb`) reads `params[:to_number]` and `params[:body]` individually and passes them as named keyword arguments into `Services::SendMessageService#call` — there is no `params.permit!`, `params.to_unsafe_h`, or blanket hash pass-through anywhere, so there is no mass-assignment vector (a client cannot inject e.g. `owner_id` or `status` via the request body; `owner_id` always comes from `current_identity`, and `status`/`external_sid` are only ever set server-side inside `SendMessageService`/gateways). Flagged Low rather than Informational only because the controller relies on selectively reading two scalar params rather than an explicit `params.require(:message).permit(:to_number, :body)` — functionally equivalent and safe today, but the more idiomatic Rails strong-params pattern would make the safety more obvious/self-documenting and harder to regress if a future dev adds a new field.

---

## Informational

### I1. Secrets handling — clean today
- No `.env`, `.env.example`, `Gemfile.lock`, or `config/master.key`/credentials files are committed anywhere in the repo (verified via filesystem search).
- `config/mongoid.yml` reads `MONGO_URI` from `ENV` with local-only defaults for dev/test and **no default in production** (`ENV.fetch("MONGO_URI")` with no fallback — will raise rather than silently connect to an unintended default), which is the correct pattern.
- `Gateways::TwilioSmsGateway` (`backend/app/gateways/twilio_sms_gateway.rb`) reads `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` exclusively via `ENV.fetch` (no defaults, so it raises loudly rather than silently using a blank/placeholder credential) and never logs the client, the credentials, or `Twilio::REST::RestError#message` (the rescued error is returned inside the gateway `Result` object and, per `Services::SendMessageService`, is never persisted or surfaced to the HTTP response — only `status: "sent"/"failed"` and `external_sid` reach the client/DB). No credential leakage found. `Gateways::FakeSmsGateway` does log per-send (`Rails.logger.info("[FakeSmsGateway] to=... body=...")`), but that data is the message content, not a secret — see **M5** for that separate (non-secrets) finding.
- `backend/config/initializers/filter_parameter_logging.rb` already filters `:auth_token`, `:account_sid`, `:token`, `:secret`, etc. from Rails logs — good proactive coverage for when Twilio params eventually flow through request logging.

### I2. Info disclosure — production config looks correct; test/dev are appropriately permissive
`config/environments/production.rb` sets `consider_all_requests_local = false` (suppresses detailed error pages/stack traces) and `config.force_ssl = true`. `config/environments/development.rb` and `test.rb` are appropriately verbose for local work. `Api::V1::MessagesController#create` (now committed) does **not** do a blanket `rescue => e; render json: { error: e.message } }` shortcut — it only ever renders the structured `result.errors` hash (validation messages defined in `SendMessageService`) or the serialized message; there is no path that surfaces a raw exception message, backtrace, or internal class/file path to the client. No issues found.

### I3. Gemfile pinning
`backend/Gemfile`: `rails ~> 7.1.0`, `mongoid ~> 9.0`, `twilio-ruby ~> 7.0`, `rack-cors` (unpinned), `rspec-rails ~> 6.1`. Pins are reasonably tight (patch-level for Rails, minor-level for others) but `rack-cors` has no version constraint at all — given CORS is a security-relevant boundary, recommend pinning it too (e.g., `gem "rack-cors", "~> 2.0"`) so a future `bundle update` can't silently change CORS matching semantics. No `Gemfile.lock` is committed (expected at this stage since `bundle install` hasn't been run in this sandbox — flagged only so the team remembers to commit it once dependencies are actually installed, so CI/prod get reproducible builds).

### I4. `CurrentIdentity` cookie is well-implemented for what it claims to be
Positives worth recording: cookie is `httponly: true` (mitigates XSS-based cookie theft), signed (tamper-evident via HMAC using `secret_key_base`), and the value itself (`SecureRandom.uuid`) is cryptographically unguessable — so even though M1/M2/M3 above raise legitimate hardening questions, there is no session-fixation vector today: the server always issues a fresh signed value when the incoming cookie is absent/invalid (`cookies.signed[COOKIE]` returns `nil` for a tampered or missing cookie, triggering re-issuance), and a client cannot set an arbitrary `owner_id` themselves because it's server-signed — an attacker-supplied plain-text cookie value will simply fail signature verification and be replaced.

### I6. CORS (CP12) landed correctly — explicit origin allow-list, credentials properly scoped
`backend/config/initializers/cors.rb` (now committed) uses `origins ENV.fetch("CORS_ORIGINS", "http://localhost:4200").split(",")` — an explicit, config-driven allow-list, **never `*`** — paired with `credentials: true` on `resource "/api/*"`, matching the frontend's `withCredentials: true` (`MessagesApiService`). Methods are restricted to `:get, :post, :options`. `.env.example` (root) documents `CORS_ORIGINS` with a safe localhost default and contains no real secrets — `TWILIO_ACCOUNT_SID`/`TWILIO_AUTH_TOKEN`/`TWILIO_FROM_NUMBER` are left blank with a comment confirming Twilio creds are not yet supplied by the client. This resolves what was originally flagged as a gap (H1 in the initial pass of this review) — no action needed beyond keeping `CORS_ORIGINS` correctly set per environment at deploy time, and revisiting alongside **M3** (`SameSite=Lax`) since both control the same cross-origin credentialed-cookie flow.

### I5. Test coverage of the security-relevant concern is present but unexecuted
`backend/spec/requests/api/v1/current_identity_spec.rb` and the `Services::Container` specs are well-written and directly test the identity-issuance/stability/uniqueness behavior described in H-adjacent findings above, but the spec file itself notes it is "hand-authored and unexecuted" in this sandbox (no `bundle install` / network access). Recommend running the full RSpec suite in a real environment before sign-off to confirm these pass as written, particularly the "issues different identities for two independent sessions" case, since it depends on the test harness's `reset!` cookie-jar behavior.

---

## Top items to close before shipping (cross-reference)

1. **H1** — no rate limiting on the send endpoint; must land before real Twilio credentials/`SMS_PROVIDER=twilio` go live anywhere reachable by untrusted clients (cost-abuse risk is real money, not theoretical — this is the only remaining High finding).
2. **M3** — `SameSite=Lax` is very likely wrong for the actual deployed topology now that CORS (CP12) is explicitly cross-origin (`localhost:4200` → `localhost:3000`, generalizing to real domains at deploy time); needs an explicit decision (proxy same-origin vs. `SameSite=None; Secure`) recorded in tech-design.md, or the identity cookie may stop round-tripping once deployed off localhost.
3. **M5** — `FakeSmsGateway` logs the full raw message body on every send; trivial one-line fix, cheap to close now before it becomes a logging-pipeline habit copied into the real Twilio path later.

CORS (previously flagged High as a gap) is now correctly implemented per **I6** and requires no further action beyond correct `CORS_ORIGINS` values at deploy time.

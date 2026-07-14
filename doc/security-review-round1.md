# MySMS Messenger — Security Review, Round 1

| | |
|---|---|
| **Reviewer** | Security Specialist |
| **Scope** | Backend CP1 (Rails skeleton), CP2 (Mongo DAL/models), CP3 (`Services::Container` IoC), CP5 (`CurrentIdentity`); Frontend CP8–CP10 (Angular skeleton, `NewMessageComponent`/`MessagesApiService`, `MessageHistoryComponent`) |
| **Method** | Static review of committed source only (read-only; no code changed) |
| **Not yet built (out of scope, noted as gaps not bugs)** | CP4/CP11 SMS gateways (`FakeSmsGateway`/`TwilioSmsGateway`), CP6/CP7 `MessagesController`/services, CP12 CORS config + `.env.example` |

---

## Summary of findings

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 3 |
| Informational | 5 |

---

## High

### H1. No CORS configuration exists yet, but `credentials: true` is already assumed by the frontend
`frontend/src/app/services/messages-api.service.ts` sends every request with `withCredentials: true`, and the design (tech-design.md §2.10) explicitly requires `credentials: true` with an explicit origin list once CORS is wired up. **CP12 (the `rack-cors` initializer) has not been committed yet** — there is no `config/initializers/cors.rb` in the backend tree at all. This is a legitimate gap for a not-yet-reached checkpoint, not a live bug, but it is flagged **High** rather than Informational because:
- The frontend is already coded assuming credentialed cross-origin requests will work, so whoever implements CP12 must not take a shortcut (e.g. `origins "*"`, which is incompatible with `credentials: true` and browsers will reject/many CORS libs silently disable the credential header) or reflect `Origin` unconditionally.
- Recommendation for CP12 implementation: origin allow-list must come from `CORS_ORIGINS` env var (as designed), must never be `*`, and should be reviewed by this role before merge.

### H2. No rate limiting on the (future) send-SMS endpoint — real cost/abuse exposure
Confirmed: no `rack-attack` or equivalent gem in `backend/Gemfile`, and `POST /api/v1/messages` (CP6/CP7) is not implemented yet, so there is currently zero throttling anywhere in the stack. Because sending real SMS via Twilio costs money per message, and the only "auth" is a self-issued signed cookie (see M1/I4 below), a client can mint unlimited identities (clear cookies / new browser / curl without cookies) and hammer the send endpoint once CP6 + CP11 (real Twilio) land. This is called out in the HLD itself (§9 Risks) as deferred, so it is not a bug in delivered code — but it must be treated as a **must-fix-before-Twilio-goes-live** item, not a nice-to-have.
- **Recommendation:** add `rack-attack` (or equivalent) keyed on `owner_id`/IP before CP11 wiring the real Twilio adapter into any environment reachable by untrusted traffic. Track this against CP11/CP12 sign-off.

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

### M4. `.gitignore` does not explicitly exclude Rails credentials/master key files
Root `.gitignore` ignores `backend/log/*`, `backend/tmp/*`, `backend/.bundle/`, `backend/vendor/bundle/`, `*.gem`, `.env`, `*.env.local`, OS files — but has **no entry for `backend/config/master.key`** or `backend/config/credentials/*.key`. No such files exist in the repo today (verified — none found), so there is no live leak, but if a future dev runs `rails credentials:edit` and generates `config/master.key`, the current `.gitignore` will not catch it before a commit. Recommend adding `backend/config/master.key` (Rails' own generator normally adds this automatically to a per-app `.gitignore`, but this repo uses a single hand-rolled root `.gitignore`, so it was missed).

---

## Low

### L1. No NoSQL injection surface in current code — confirm this holds as controllers land
`MongoMessageRepository#find_for_owner` (`backend/app/repositories/mongo_message_repository.rb`) builds its Mongoid query as `MessageDocument.where(owner_id: owner_id)`, i.e., `owner_id` is passed as a plain string value, not as a raw hash/operator fragment from user input — this is currently safe. There is no `messages_controller.rb` yet (CP6/CP7 not committed), so there's nothing exploitable today. **Action for round 2:** when CP6/CP7 land, verify the controller passes `current_identity` (a value the server itself generated) rather than any client-supplied `params[...]` into `.where(...)`, and verify `to_number`/`body` are never interpolated into a raw Mongo operator hash (e.g., no `params[:filter]` merged into a `where` clause) — that would be the classic Mongoid NoSQL-injection vector (`{"$where" => ...}` or operator injection via `params.permit!`).

### L2. XSS: current Angular templates are safe by default, but there is no explicit test/lint guard against future regressions
Reviewed `message-history.component.html` and `new-message.component.html`: message bodies and phone numbers are rendered exclusively via Angular interpolation (`{{ message.body }}`, `{{ message.to_number }}`), which Angular auto-escapes (contextual output encoding). **No `[innerHTML]`, `bypassSecurityTrust*`, or `DomSanitizer` usage anywhere in the frontend tree** (confirmed via full-tree read of all `.ts`/`.html` files) — this is the correct, safe default and there is no live XSS today. Flagged Low only as a process recommendation: add an ESLint rule (e.g. `@angular-eslint` `no-inner-html` or similar) so a future dev cannot introduce `[innerHTML]` binding of the (user-supplied) message `body` field without a deliberate sanitizer review.

### L3. Strong-params / mass-assignment cannot yet be assessed — no controller exists
CP6/CP7's `MessagesController#create` is specified in tech-design.md §2.8 as calling the service with explicitly named `params[:to_number]`/`params[:body]` (not `params.permit(...).to_h` blanket-passed, and not `params.require(:message).permit!`), which if implemented as documented is safe. Since the controller file does not exist in the current commit, this cannot be verified against real code yet — flagged as a round-2 checklist item, not a current bug.

---

## Informational

### I1. Secrets handling — clean today
- No `.env`, `.env.example`, `Gemfile.lock`, or `config/master.key`/credentials files are committed anywhere in the repo (verified via filesystem search).
- `config/mongoid.yml` reads `MONGO_URI` from `ENV` with local-only defaults for dev/test and **no default in production** (`ENV.fetch("MONGO_URI")` with no fallback — will raise rather than silently connect to an unintended default), which is the correct pattern.
- `Gateways::FakeSmsGateway`/`Gateways::TwilioSmsGateway` do not exist in the committed tree yet (CP4/CP11 not reached), so there is nothing to review for credential logging today. **Round-2 checklist:** when `TwilioSmsGateway` lands, confirm it never logs `TWILIO_AUTH_TOKEN` (e.g., via an accidental `Rails.logger.info(client.inspect)` or exception message that embeds the token) and that `filter_parameter_logging.rb` (see below) covers any params that might carry it.
- `backend/config/initializers/filter_parameter_logging.rb` already filters `:auth_token`, `:account_sid`, `:token`, `:secret`, etc. from Rails logs — good proactive coverage for when Twilio params eventually flow through request logging.

### I2. Info disclosure — production config looks correct; test/dev are appropriately permissive
`config/environments/production.rb` sets `consider_all_requests_local = false` (suppresses detailed error pages/stack traces) and `config.force_ssl = true`. `config/environments/development.rb` and `test.rb` are appropriately verbose for local work. No issues found. Note: once `MessagesController` exists, confirm it never does a blanket `rescue => e; render json: { error: e.message, backtrace: e.backtrace }` — a common junior-dev shortcut that leaks internals. Add to round-2 checklist.

### I3. Gemfile pinning
`backend/Gemfile`: `rails ~> 7.1.0`, `mongoid ~> 9.0`, `twilio-ruby ~> 7.0`, `rack-cors` (unpinned), `rspec-rails ~> 6.1`. Pins are reasonably tight (patch-level for Rails, minor-level for others) but `rack-cors` has no version constraint at all — given CORS is a security-relevant boundary, recommend pinning it too (e.g., `gem "rack-cors", "~> 2.0"`) so a future `bundle update` can't silently change CORS matching semantics. No `Gemfile.lock` is committed (expected at this stage since `bundle install` hasn't been run in this sandbox — flagged only so the team remembers to commit it once dependencies are actually installed, so CI/prod get reproducible builds).

### I4. `CurrentIdentity` cookie is well-implemented for what it claims to be
Positives worth recording: cookie is `httponly: true` (mitigates XSS-based cookie theft), signed (tamper-evident via HMAC using `secret_key_base`), and the value itself (`SecureRandom.uuid`) is cryptographically unguessable — so even though M1/M2/M3 above raise legitimate hardening questions, there is no session-fixation vector today: the server always issues a fresh signed value when the incoming cookie is absent/invalid (`cookies.signed[COOKIE]` returns `nil` for a tampered or missing cookie, triggering re-issuance), and a client cannot set an arbitrary `owner_id` themselves because it's server-signed — an attacker-supplied plain-text cookie value will simply fail signature verification and be replaced.

### I5. Test coverage of the security-relevant concern is present but unexecuted
`backend/spec/requests/api/v1/current_identity_spec.rb` and the `Services::Container` specs are well-written and directly test the identity-issuance/stability/uniqueness behavior described in H-adjacent findings above, but the spec file itself notes it is "hand-authored and unexecuted" in this sandbox (no `bundle install` / network access). Recommend running the full RSpec suite in a real environment before sign-off to confirm these pass as written, particularly the "issues different identities for two independent sessions" case, since it depends on the test harness's `reset!` cookie-jar behavior.

---

## Top items to close before shipping (cross-reference)

1. **H2** — no rate limiting on the send endpoint; must land before real Twilio credentials go live anywhere reachable by untrusted clients (cost-abuse risk is real money, not theoretical).
2. **H1** — CORS is not implemented yet, but the frontend already assumes credentialed cross-origin calls; whoever implements CP12 must use an explicit origin allow-list (never `*`) and this config should get a follow-up review.
3. **M3** — `SameSite=Lax` is very likely wrong for the actual deployed topology (cross-origin SPA + API); needs an explicit decision (proxy same-origin vs. `SameSite=None; Secure`) recorded in tech-design.md before CP12, or the identity cookie may stop working in anything other than a same-origin/dev-proxied setup.

# QA + Security Review — Bonus 1 Authentication

Reviewer: QA / Chaos Engineering pass (independent, read-only)
Scope: `doc/tech-design.md` §13 vs. the actual committed code on this branch
(commits `94d0614`…`2dced15`, CP13–CP18).

## Top-line verdict

**CONDITIONAL PASS — the auth feature itself is well-built and matches the
locked design, but the test-coverage story around it is materially
misrepresented and must be fixed before this is "done."** The three
pre-existing RSpec request specs were never updated for the new
auth-required `CurrentIdentity` and are now stale/would-fail; zero new
RSpec coverage exists for `User`, `AuthController`, or the login throttle
despite the tech design's own checkpoint acceptance criteria (CP13–CP16)
requiring it; and the backend health check (`GET /health`) now 401s for
everyone, which is a deploy-breaking regression, not a hypothetical.
No critical *exploitable* vulnerability was found in the shipped auth logic
itself (password handling, CORS, cookie clearing, and authorization
scoping all check out). Signup is confirmed unthrottled, as flagged in the
design's own open questions.

**Findings: 1 Critical, 2 High, 3 Medium, 3 Low, 3 Informational (security)
+ 1 Blocker, 2 Major, 3 Minor, 2 Nitpick (QA).**

---

## Security Findings

### Critical

**C1 — `GET /health` now requires authentication and will 401 for load
balancers / uptime monitors.**
`HealthController < ApplicationController` does not
`skip_before_action :resolve_current_identity`, and `CurrentIdentity#resolve_current_identity`
(backend/app/controllers/concerns/current_identity.rb) now renders 401 for
any request without a valid signed user-id cookie. A health check is, by
definition, called with no cookie. This isn't a security bug per se, but it
is a critical operational regression introduced by the Bonus 1 rework
(previously `/health` "worked" because the old `CurrentIdentity` silently
minted an anonymous UUID for anyone). If a real deployment's load balancer
or orchestrator treats a 401 on `/health` as "unhealthy," this takes the
whole service down. Needs `skip_before_action :resolve_current_identity` on
`HealthController` (mirroring `auth#signup/login/logout`).

### High

**H1 — Existing request specs are stale for the new auth-required model and
were never updated; this is undisclosed regression, not "unexecuted, but
accurate documentation."**
`backend/spec/requests/api/v1/current_identity_spec.rb`,
`messages_create_spec.rb`, and `messages_index_spec.rb` all assert the
*old* anonymous-identity-minting contract: "issues a signed owner cookie on
first contact," `GET /health` / `POST/GET /api/v1/messages` returning
200/201 with **no prior login**. Under the actual Bonus 1 code these calls
now 401 (`CurrentIdentity` requires a real authenticated user). The
in-repo comments claim these specs are "unexecuted... but remain accurate
documentation for a real Rails environment" — that claim is false as of
this branch; they are stale and would fail the moment `bundle install`
succeeds. This matters because CP15's own acceptance criteria
("request spec proves `/api/v1/messages` 401s unauthenticated and scopes
to `user.id` when authed") was never actually delivered — the spec that
exists proves the *opposite* of the new contract.

**H2 — Zero test coverage (RSpec or otherwise) for `User`, `AuthController`,
`CurrentIdentity`'s new auth-required path, or the rack-attack login
throttle, despite the tech design mandating it.**
`doc/tech-design.md` §13.8 checkpoint table requires, verbatim: a `User`
model spec ("digest set not plaintext, `authenticate` works, dup username
rejected" — CP13), an `AuthController` request spec covering all four
endpoints plus "enumeration-safe 401" (CP14), a `CurrentIdentity` request
spec proving 401/authenticated scoping (CP15), and a rack-attack spec
proving the 6th login attempt 429s (CP16). None of these exist anywhere in
`backend/spec/` or `backend/test/`. The zero-gem Minitest suite
(`backend/test/`, the only *actually executable* backend suite in this
sandbox) doesn't touch `User`/auth at all — it only covers the
framework-independent domain/services/gateway layer. Net effect: **the
entire Bonus 1 backend auth implementation has never been executed by any
test, anywhere, by anyone**, and nothing in the repo currently proves
`has_secure_password`, the login flow, the 401 gate, or the throttle
actually work end-to-end. Given this is a hand-authored, self-reviewed
change with an explicit "unexecuted in sandbox" excuse baked into every
adjacent spec file, this needs to be validated in a real Rails environment
before being called done.

### Medium

**M1 — Timing-based username enumeration is real and only "accepted," not
mitigated, per the design's own admission (§13.4 note).**
`AuthController#login` (backend/app/controllers/api/v1/auth_controller.rb)
does return the same generic `{"errors":{"base":["Invalid username or
password"]}}` for both "no such user" and "wrong password" — good, no
*content*-based enumeration. But `user&.authenticate(...)` short-circuits
via Ruby's `&.` when `user` is `nil`, skipping the bcrypt compare entirely,
so a nonexistent-username request returns measurably faster than a
wrong-password request against a real username. This is a genuine,
measurable timing side-channel an attacker can use to enumerate valid
usernames (bcrypt compares are ~50-250ms; a DB miss is sub-millisecond).
The tech design flags this explicitly as an "accepted low risk" for a
pre-launch app and suggests a dummy `BCrypt::Password.create` compare on
the miss path as the fix if tightened later. Flagging it here as a Medium
because it's a known, unmitigated, and measurable leak, not a theoretical
one — worth doing the one-line dummy-hash fix now since it's cheap.

**M2 — Signup is confirmed completely unthrottled.**
Verified: `rack_attack.rb` only throttles `POST /api/v1/auth/login`
(`auth/login/ip`, 5/60s) and `POST /api/v1/messages`
(`messages/send/owner_id`, 10/60s). There is no throttle rule anywhere for
`POST /api/v1/auth/signup`. This matches tech-design.md §13.9's own open
question #2 ("Registration is currently open and unthrottled"), so it's
disclosed, not hidden — but it is a live gap: unlimited account creation
enables automated abuse (spam accounts, credential-stuffing prep, or using
signup as a disguised brute-force oracle since `authenticate` isn't in the
signup path but username-uniqueness errors on signup ARE distinguishable
from "created," which is a *separate*, un-mitigated enumeration vector —
see M3). Severity Medium because the cost/blast-radius (compute + Mongo
writes, not Twilio spend) is lower than the messages endpoint this pattern
was originally built to protect.

**M3 — Signup's 422 uniqueness error is a clean, un-throttled username
oracle.**
`User` validates `uniqueness: true` on `username`, and
`AuthController#signup` returns `422 {"errors":{"username":["is already
taken"]}}` verbatim on collision. Combined with M2 (no throttle), an
attacker can enumerate the entire universe of registered usernames for
free via repeated signup attempts — a much cheaper and more precise oracle
than the login-timing side channel in M1. This is arguably a bigger real
enumeration risk than the login path the design explicitly reasoned about
in §13.4, and it's less bounded (5/60s) than login. Recommend: throttle
signup like login, and/or return a generic "unable to create account"
message without confirming which field collided (usability trade-off, but
worth calling out).

### Low

**L1 — 1-year cookie lifetime with no server-side revocation, already
flagged in the design (§13.9 Q4) but worth restating as a residual risk**:
a stolen/leaked signed cookie is valid for a year and can only be killed by
rotating `secret_key_base` (which invalidates *everyone's* session). No
idle timeout either.

**L2 — Password policy is minimum-length-only (8 chars), no complexity or
breach-list check** — explicitly called out as an accepted, non-blocking
trade-off in §13.9 Q5. Not a finding beyond confirming it's implemented as
documented.

**L3 — `password_digest` field.** Confirmed never serialized: `user_json`
in `AuthController` explicitly whitelists `{id, username}` only, on
signup/login/me. No response path returns the digest. Also confirmed
`has_secure_password` (bcrypt) is used — no plaintext password field
exists on the model, no plaintext appears in any `render json:` call, and
no `Rails.logger`/`puts` call anywhere in the auth path logs `params[:password]`
or the digest. Clean. (Downgraded from a checklist item to Low/Informational
because it passed.)

### Informational

**I1 — Rack::Attack login-throttle wiring is correct.** Verified the rule
path/method match (`req.post? && req.path == "/api/v1/auth/login"`), the
key (`req.ip`), and that it sits in the same `unless Rails.env.test? ||
RACK_ATTACK_DISABLED` guard as the pre-existing messages throttle, so it
won't fire in specs (moot today since no auth specs exist — see H2 — but
correct as written) and can be emergency-killed via ENV. No
cross-contamination with the messages throttle (different key names,
independent `throttle` blocks). IP-only keying is a reasonable, documented
trade-off (shared-NAT false positives possible but low severity for a
pre-launch app).

**I2 — CORS `:delete` addition is correct and necessary**, and was in fact
made (`config/initializers/cors.rb` now lists
`methods: [:get, :post, :delete, :options]`) — without it, `DELETE
/api/v1/auth/logout` would fail as a CORS-blocked preflight from the
Angular dev server. Confirmed frontend `AuthApiService.logout()` uses
`this.http.delete(...)` with `withCredentials: true`, matching.

**I3 — Cookie clear-on-logout attributes match cookie-set attributes.**
`sign_out` calls `cookies.delete(COOKIE, same_site: same_site_policy,
secure: secure_cookie?)` — same `same_site`/`secure` computation used by
`sign_in`. Rails' cookie deletion also implicitly uses the same `path`
(default `/`) as the original set, so the browser will match and drop it
correctly. No stale-cookie-that-looks-cleared-but-isn't issue found.

---

## QA Findings

### Blocker

**B1 (= security C1 above, restated as QA).** `GET /health` 401ing for
unauthenticated callers breaks the health-check contract CP1 originally
established. This is a functional regression on a previously-passing
endpoint, caused by CurrentIdentity's blanket `before_action`, and it will
fail in any real deploy with a load balancer / readiness probe hitting
`/health` before any user has ever logged in.

### Major

**MAJ1 — Stale request specs (H1) will fail as soon as they're actually
run**, i.e. the first real `bundle install` + `bundle exec rspec` in a
non-sandboxed environment will show regressions on day one of this
branch reaching a real CI runner. This should be caught now, not
discovered post-merge.

**MAJ2 — No frontend or backend test proves the cross-user authorization
boundary (item 5 in the review charter) end-to-end with two *real*
authenticated users.** Manual code read confirms `MessagesController`
still scopes via `current_identity` (backend/app/controllers/concerns/current_identity.rb:
`current_identity = @current_user&.id&.to_s`), which now derives from the
authenticated `@current_user`, so the wiring is architecturally sound — a
logged-in user cannot see/send as another user because `owner_id` is never
taken from client input, only from server-resolved `current_identity`.
But there is no automated test (RSpec or Minitest) that logs in as user A,
sends a message, logs in as user B, and asserts B's `GET
/api/v1/messages` list is empty / doesn't include A's message. The old
`messages_index_spec.rb`'s "scopes to current identity" test exercises the
*old* anonymous-cookie-swap mechanism, not two real authenticated users, so
it doesn't actually cover this boundary under the new model either.

### Minor

**MIN1 — Frontend auth guard is correctly a "real" gate, not just
visual.** Confirmed: `app.component.html` wraps the entire messenger
`<main>` in `@if (checked$ | async) { @if (loggedIn$ | async) {...} }` —
an Angular `@if` structural directive, so `MessageHistoryComponent` and
`NewMessageComponent` (and their `ngOnInit` calls that hit the API) are
never *instantiated* while logged out, not merely hidden with CSS. No
data-fetch-before-auth-check race found. `checked$` starts `false` and the
whole `<main>` block is absent from the DOM until `checkSession()`
resolves, so there's no flash-of-messenger-then-kick-to-login either.

**MIN2 — 401-triggered logout wiring is correct but only covers the two
message endpoints.** `MessagesApiService.handleAuthExpiry()` correctly
calls `authStore.clearSession()` only on `err.status === 401` and
rethrows in all cases (verified — no swallowed errors, no stuck spinner
since `MessagesStoreService`'s `catchError` always calls
`loadingSubject.next(false)`). This is fine for the two message endpoints
per CP18's scope, just noting it's not a generic HTTP interceptor, so any
*future* authenticated endpoint added outside `MessagesApiService` would
need the same pattern copy-pasted or it won't self-heal on session expiry.

**MIN3 — Input validation on signup returns clean 422s, not 500s, for the
tested edge cases.** Verified via code (not runtime, per H2): empty
username/password → `has_secure_password` presence validation + `format`
regex reject before hitting bcrypt; the format regex
(`/\A[a-z0-9_]{3,30}\z/`) is anchored (`\A`/`\z`, not `^`/`$`) so
embedded-newline bypass tricks don't work; oversized password input is
capped by bcrypt's own 72-byte limit (raises an `ActiveModel` validation
error via `has_secure_password`, not an unhandled exception); non-string
`username`/`password` params (e.g. a nested hash injection like
`username[a]=1`) aren't explicitly guarded the way
`SendMessageService#validate` guards `to_number`/`body` (MAJ1/MAJ2 fix
noted in that file's comments) — `User.new(username: params[:username],
...)` would receive an `ActionController::Parameters` hash instead of a
String, and `before_validation { username.downcase.strip if
username.is_a?(String) }` would just skip normalization (guarded by
`is_a?(String)`), then the `format` validation would fail cleanly since a
Hash doesn't match the regex — so it still degrades to a 422, not a 500,
but only by accident of the `is_a?(String)` guard already being there for
a different reason, not because anyone explicitly defended this input
class the way `SendMessageService` does. Worth a deliberate test, not just
a lucky code path.

### Nitpick

**NIT1** — `current_identity_spec.rb`'s file-level comment block should be
corrected or the file removed/renamed; as written it actively asserts
behavior (anonymous cookie minting on `/health`) that contradicts the
locked, shipped design and will mislead the next reader into thinking it's
current documentation.

**NIT2** — Consider renaming the "backwards-compatible alias"
`current_identity` in `CurrentIdentity` to something auth-explicit (e.g.
`current_owner_id`) in a follow-up — functionally correct today, but the
comment referencing "the superseded implementation" for context that a
future reader won't have (git history reference) is a maintenance smell.

---

## Item-by-item confirmation (review charter checklist)

1. **Password handling** — Pass. bcrypt via `has_secure_password`; digest
   never serialized; no plaintext logging found.
2. **Timing/enumeration** — Partial. No content-based enumeration (generic
   error both paths). Timing-based enumeration on login IS present and
   accepted/disclosed by design (M1); signup's 422 collision message is an
   *undisclosed*, unthrottled, more precise oracle (M3).
3. **Brute force / rack-attack wiring** — Pass. Correct path/method/key,
   correctly scoped, doesn't cross-contaminate the messages throttle (I1).
4. **Session/cookie correctness** — Pass. Old anonymous cookies cleanly
   401 (no crash); `sign_in`/`sign_out` set/clear correctly; logout is
   `DELETE`, CORS allows it, attributes match on clear (I2/I3).
5. **Authorization boundary** — Architecturally sound by code read
   (MAJ2), but **unverified by any test** — no automated two-user
   cross-access test exists.
6. **Signup abuse** — Confirmed unthrottled (M2), as disclosed in
   tech-design.md §13.9 Q2.
7. **Input validation** — Mostly pass; degrades to 422 not 500 for tested
   edge cases, but non-string param handling is accidental rather than
   deliberate (MIN3).
8. **Frontend auth guard / checkSession / 401 handling** — Pass (MIN1,
   MIN2).
9. **Dead code / old anonymous-identity expectations** — Found: three
   stale RSpec request specs (H1) still assert the old silent-success
   behavior; `HealthController` still implicitly expects unauthenticated
   success (C1/B1), which is the one place old behavior is still
   *architecturally* assumed, not just documented.
10. **Test count verification** — See below.

---

## Test re-run results (actually executed, not taken on faith)

- **Frontend (`npx ng test --watch=false`, headless Chromium via a locally
  available Playwright browser):** **74/74 passed**, 11 test files, 3.70s.
  Confirmed accurate.
- **Backend Minitest (`ruby backend/test/run_all.rb`):** **33/33 passed**
  (33 runs, 90 assertions, 0 failures/errors). Confirmed accurate — **but
  note this suite is the pre-existing, framework-independent
  domain/services/gateway suite and contains zero coverage of `User`,
  `AuthController`, `CurrentIdentity`, or rack-attack.** The "33/33" number
  is real but does not speak to Bonus 1 at all.
- **Backend RSpec (`bundle exec rspec`):** **Could not be executed** — no
  network access in this sandbox to `bundle install` (Rails/Mongoid/RSpec/
  bcrypt/rack-attack/rack-cors are not installed; no `Gemfile.lock` is
  committed; system Ruby is 3.0.2 vs. the app's pinned 3.3.0). This matches
  the limitation already disclosed in the repo's own spec comments and
  README — but it also means **the RSpec suite, including all Bonus 1
  backend coverage that theoretically exists, has never actually been run
  by anyone in this environment**, and as shown in H1, three of its
  existing specs are stale and would fail if it were runnable. The claimed
  passing state of the RSpec suite could not be verified and should not be
  assumed green until run in a real Rails-capable environment.

## Recommended fix order before calling Bonus 1 done

1. **B1/C1** — `skip_before_action :resolve_current_identity` on
   `HealthController` (one line, prevents a real outage).
2. **H1** — Rewrite the three stale request specs for the auth-required
   contract (login first, then hit the endpoint), and add the CP13/CP14/
   CP15/CP16 specs the tech design explicitly requires (H2), including a
   real two-user cross-access test (MAJ2).
3. **M3** — Throttle or genericize the signup uniqueness-collision
   response; it's currently a cheaper, unthrottled username oracle than
   the login-timing channel the design already reasoned about.

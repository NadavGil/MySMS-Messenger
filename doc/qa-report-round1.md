# MySMS Messenger — QA / Chaos Engineering Report, Round 1

**Reviewer:** QA & Chaos Engineer
**Scope:** Backend CP1, CP2, CP3, CP5. Frontend CP8, CP9, CP10.
**Method:** Read every committed source file under `backend/app`, `backend/config`,
`backend/spec`, and `frontend/src`, cross-referenced against `doc/HLD.md` and
`doc/tech-design.md`. No application code was modified. RSpec/Karma specs were
read but not executed (sandbox has no network/Chrome — see §5 in tech-design and
the note in `current_identity_spec.rb`); their logic is assessed by inspection.

**Scope reminder:** `Api::V1::MessagesController`, `SendMessageService`,
`ListMessagesService`, and the Twilio gateway (CP4/6/7/11) do not exist yet.
Several findings below are "pre-loaded landmines" for those future checkpoints
rather than defects in currently-runnable behavior — each is labeled.

---

## Blocker

**B1. `Services::Container#message_repository` creates a brand-new,
unshared repository instance on every call — breaks `MESSAGE_REPOSITORY=in_memory`
across requests.**
`backend/app/services/container.rb:26-28`:
```ruby
def message_repository
  Rails.configuration.x.message_repository_class.constantize.new
end
```
`Repositories::InMemoryMessageRepository#initialize` sets `@records = []`
(`backend/app/repositories/in_memory_message_repository.rb:11-13`). Because the
container calls `.new` fresh every time it's asked for a repository, a
`create` in one call and a `find_for_owner` in the next call operate on two
different, throwaway arrays. Once CP6/CP7 controllers call
`Container.send_message_service` for `POST` and `Container.list_messages_service`
for `GET`, every `GET /api/v1/messages` will return `[]` even immediately after a
successful `POST`, whenever `MESSAGE_REPOSITORY=in_memory` is set (the
documented "fast demo" mode per tech-design §3.3/§11). `MongoMessageRepository`
is unaffected (it's a stateless wrapper over the real Mongo collection), so this
only manifests for the in-memory backend — but that's an explicitly supported,
documented run mode.
Not caught by `backend/spec/services/container_spec.rb` because that spec only
asserts `be_a(...)` on a single call per example; it never calls
`message_repository` twice and checks that state survives.
Note: this exact per-call `.new` pattern is copied verbatim from
tech-design.md §2.6's own pseudocode, so it's an inherited design flaw, not a
CP3 regression — but it is now committed code and will silently break demos/dev
use unless the in-memory instance is memoized (e.g., class-level singleton or
`||=`) before CP6/7 land.

---

## Major

**M1. `SameSite=:lax` signed cookie will not round-trip once frontend and
backend are on different registrable domains (Bonus 2 / production).**
`backend/app/controllers/concerns/current_identity.rb:24-30` sets
`same_site: :lax`. `SameSite=Lax` cookies are withheld by browsers on
cross-site XHR/fetch subresource requests (only top-level navigations get
them). Angular's `HttpClient` calls (`messages-api.service.ts`) are always
fetch/XHR, never a top-level navigation. Locally this "accidentally" works
because Chrome/Firefox treat `localhost:4200` and `localhost:3000` as
same-site (SameSite only cares about registrable domain, not port). The moment
the SPA and API live on genuinely different domains — exactly the scenario HLD
§8/Bonus 2 anticipates — the identity cookie stops being sent on `GET`/`POST`
`/api/v1/messages`, and `CurrentIdentity` mints a brand-new session on every
single request, silently breaking per-session scoping. Needs `same_site: :none`
+ `secure: true`, env-gated, before any cross-domain deploy.

**M2. Production `apiBaseUrl` double-prefixes `/api`.**
`frontend/src/environments/environment.production.ts:3`: `apiBaseUrl: '/api'`.
`frontend/src/app/services/messages-api.service.ts:17`:
`private readonly baseUrl = \`${environment.apiBaseUrl}/api/v1/messages\`;`
In the production build this resolves to `/api/api/v1/messages` — a guaranteed
404 against the real Rails routes (`/api/v1/messages`, `config/routes.rb:4-10`).
Dev/development environments both use a full origin (`http://localhost:3000`),
which masks the bug entirely in local testing. Needs a fix (either
`apiBaseUrl: ''` with the service keeping `/api/v1/messages`, or
`apiBaseUrl: '/api/v1'` and the service dropping the duplicate segment) before
any Bonus-2 cloud deploy or CP12 integration smoke test.

**M3. Concurrent "first contact" race can orphan a message under a discarded
identity.**
`MessageHistoryComponent.ngOnInit` (`message-history.component.ts:41-43`) fires
`store.refresh()` (a `GET`) immediately on load. If a user also submits the
New Message form before any `msms_owner` cookie exists yet (e.g., slow network,
double first requests in flight), both requests hit
`current_identity.rb:19-31` with no existing cookie and each mints and sets a
*different* `SecureRandom.uuid`. Whichever `Set-Cookie` the browser applies
last "wins"; the message created under the other minted identity becomes
permanently invisible to that browser (its `owner_id` will never again match
a cookie the browser presents). This is a narrow window but real, and gets
easier to hit under real network latency/replay. Worth a design note now;
likely needs the client to make a single "bootstrap" call before firing
parallel requests, or the server to make identity issuance idempotent within a
race window.

**M4. `MessagesStoreService.refresh()` has no request cancellation — overlapping
GETs can let a stale response overwrite fresher data.**
`backend/`... (frontend) `messages-store.service.ts:27-44`: each call to
`refresh()` starts a new `listMessages()` subscription with no `switchMap`,
`takeUntil`, or in-flight guard. `refresh()` is called both from
`ngOnInit` and after every successful send. If two refreshes overlap (fast
double-submit, or a send completing right as the initial load is still
in-flight) and the earlier request's response arrives after the later one's,
`messagesSubject.next(response.messages)` in the *stale* callback will
overwrite the newer list, so the UI can transiently (or, if the user then does
nothing else, permanently) show outdated history. Recommend `switchMap` in a
single persistent stream rather than one-off `.subscribe()` calls.

**M5. No committed `secret_key_base` source (no `config/master.key` /
`config/credentials.yml.enc`).**
`CurrentIdentity` depends on `cookies.signed`, which depends on
`secret_key_base`. In dev/test Rails auto-generates and caches a fallback
secret (`tmp/local_secret.txt`) so this doesn't block CP1-CP5 locally, but
production (`config/environments/production.rb`) has no override and no
`RAILS_MASTER_KEY`/`SECRET_KEY_BASE` is documented anywhere (not even in the
`.env.example` — which doesn't exist yet either, see Minor M9). Flag so CP12's
env-var/README pass explicitly covers this or the signed cookie will either
fail to boot or (worse) work with a key nobody rotated/tracked.

---

## Minor

**N1. Grapheme/codepoint/UTF-16 length mismatch for the 250-char limit.**
`new-message.component.ts` uses `Validators.maxLength(250)` and
`body.length` (JS UTF-16 code-unit count); `message-history.component.html:19`
does the same (`message.body.length`). Once the (not-yet-built) Ruby-side
validation lands (tech-design §6.1, `body.length` presumably via Ruby
`String#length`, which counts Unicode codepoints, not UTF-16 units, not
grapheme clusters), a string containing surrogate-pair emoji or combining
marks can count differently client-side vs. server-side — e.g. a message that
reads as 248 "characters" in the browser could be over/under the limit once
validated in Ruby. Not exploitable today (no server validation exists yet),
but the two future implementations should agree on one canonical unit before
CP6 is built, and true grapheme-cluster-accurate counting should be explicitly
declared out of scope if that's the decision.

**N2. `InMemoryMessageRepository` has no thread-safety once B1 is fixed.**
Today each `Container.message_repository` call gets its own instance (B1), so
there's nothing to race on. But the natural fix for B1 (memoize a
shared/singleton instance) will reintroduce a real hazard: `@records << message`
in `create` (`in_memory_message_repository.rb:25`) and the `sort_by...reverse`
scan in `find_for_owner` are not synchronized. Under Puma's threaded mode with
concurrent requests, this needs a `Mutex` around mutations once it becomes a
shared instance. Flagging now to avoid a second bug appearing right after B1 is
patched.

**N3. `MongoMessageRepository` does not rescue Mongo connectivity failures.**
`backend/app/repositories/mongo_message_repository.rb:9` (`create!`) and
`:20-23` (`find_for_owner`) let any `Mongo::Error` (connection refused, replica
set failover, timeout) propagate unhandled. Once wired into
`SendMessageService`/`ListMessagesService` (CP6/7), a Mongo outage will surface
as a generic unhandled-exception 500, not the `{errors: {...}}` shape the API
contract documents for anything else. Worth deciding at CP6/7 whether the
service layer wraps/rescues this into a structured 5xx.

**N4. `.env.example` (tech-design §11) doesn't exist yet.**
Reasonable to defer to CP12 per the checkpoint plan's ordering, but flag now so
it isn't forgotten — several of the findings above (M5, container ENV
misconfiguration below) would be easier to catch with it in place earlier.

**N5. Garbage `MESSAGE_REPOSITORY`/`SMS_PROVIDER` values behave correctly
(hard fail, not silent fallback) — verified as a pass, not a defect.**
`config/initializers/container.rb:17-19,31-33` raises `ArgumentError` with a
clear message for unrecognized values via `Hash#fetch` with a block, rather
than silently defaulting. `container_initializer_spec.rb:53-57` exercises this
for `MESSAGE_REPOSITORY=postgres`. Good: an unset var falls back to documented
per-environment defaults; a garbage value fails loud at boot rather than
degrading silently. No equivalent spec exists for a garbage `SMS_PROVIDER`
value, though the code path is symmetric — cheap to add.

---

## Nitpick

**P1. Angular pinned at `^22.0.0`** (`frontend/package.json`) vs.
tech-design.md §0's locked "Angular 17/18 (latest stable)". Almost certainly
intentional ("latest stable" drifted forward since the doc was written), but
flag for the same explicit sign-off treatment CP3 gave the `Services::Container`
naming deviation.

**P2. `sort_by(&:created_at).reverse` in `find_for_owner`**
(`in_memory_message_repository.rb:30-32`) is O(n log n) per read and
re-sorts every call; fine at this data scale, purely a style note (an
insert-sorted array or reverse-append would avoid the resort).

**P3. `shared_examples`'s "returns newest-first" test uses `sleep 0.01`**
(`spec/support/shared_examples/message_repository_examples.rb:56-58`) to force
distinct timestamps. Works, but is slightly flaky/slow style; a monotonic
counter or injected clock would be more robust and faster.

**P4. XSS via message body: verified safe, no defect found.**
Searched all of `frontend/src` for `innerHTML`, `bypassSecurityTrust*`, and
`DomSanitizer` — none found. `message-history.component.html:18` renders
`{{ message.body }}` via plain Angular interpolation, which HTML-escapes by
default. A payload like `<script>alert(1)</script>` or `<img onerror=...>` in
the message body will render as inert text, not execute. Called out
explicitly since it was a specific chaos-test target — currently clean.

**P5. Cookie tampering: verified safe, no defect found.**
`cookies.signed[COOKIE]` (`current_identity.rb:20`) returns `nil` for any
tampered/invalid signature (Rails verifies the signature before returning a
value), which correctly falls through to minting a fresh identity
(`:22-31`) rather than raising or leaking the previous owner's data. No crash,
no cross-session leak from a manually edited cookie value.

---

## Test-logic assessment (unexecuted specs, read-only review)

All specs below were read but not run (sandbox has no bundler/network per the
note in `current_identity_spec.rb:9-11` and the tech-design's own CP acceptance
notes). Logic assessment:

- **`spec/config/container_initializer_spec.rb`** — sound. Faithfully fakes
  `Rails.configuration`/`Rails.env` to load the initializer standalone; covers
  test/dev defaults, explicit override, and the garbage-value raise. Would
  pass as written.
- **`spec/services/container_spec.rb`** — sound but incomplete: proves type
  resolution (`be_a(...)`) correctly, but never asserts that two calls to
  `message_repository` return a *shared* instance — which is exactly how it
  misses Blocker B1. Recommend adding an assertion like
  `expect(Services::Container.message_repository).to equal(Services::Container.message_repository)`
  (or equivalent behavioral check that a create then a find on two separate
  `Container.*_service` calls sees the same data) to catch B1 mechanically.
- **`spec/repositories/in_memory_message_repository_spec.rb`** +
  shared examples — sound, plain-Ruby, no Rails boot needed; correctly proves
  create/find/isolation/ordering contract. `sleep 0.01` noted at P3 above but
  not a logic defect.
- **`spec/requests/api/v1/current_identity_spec.rb`** — logic is sound
  (issues-cookie, stable-across-requests-with-cookie-replayed,
  different-per-session-after-`reset!`), but it depends on a full Rails boot
  (`rails_helper`) that could not be exercised in this sandbox. One soft spot:
  the "keeps the same identity" test does
  `second_cookie = response.cookies["msms_owner"] || first_cookie` — if the
  second request's response legitimately omits re-setting the cookie (expected,
  since it was already present and valid), the test degrades to comparing
  `first_cookie` to itself, which would pass even if `resolve_current_identity`
  were subtly broken in a way that only manifests on `cookies.signed` read (not
  write). A stronger assertion would inspect the *request-scoped*
  `current_identity` value (e.g., via a debug echo route) rather than only the
  `Set-Cookie` header, which isn't always resent.
- **Frontend Karma specs** (`new-message.component.spec.ts`,
  `message-history.component.spec.ts`, `messages-api.service.spec.ts`,
  `utc-timestamp.pipe.spec.ts`, `app.component.spec.ts`) — all logically sound
  and reasonably thorough (form validity, disabled Submit, 250-char maxlength
  rejection, live counter, Clear, success/error submit paths, loading/empty/error
  states for history, `withCredentials` assertion, UTC formatting incl.
  padding). None currently exercise M2 (double `/api` prefix) since all specs
  use the dev `environment.ts`/`environment.development.ts`, which does not
  hit the bug — worth adding a dedicated unit test against
  `environment.production.ts`'s value to catch regressions like M2 mechanically.
  None exercise emoji/grapheme edge cases (N1) or overlapping-refresh races (M4).

---

## Summary

| Severity | Count |
|---|---|
| Blocker | 1 |
| Major | 5 |
| Minor | 5 (incl. 2 verified-safe passes) |
| Nitpick | 5 (incl. 2 verified-safe passes) |

**Top 3 to fix before continuing:**
1. **B1** — `Services::Container#message_repository` must not instantiate a
   fresh `InMemoryMessageRepository` on every call; memoize it, or the
   documented `MESSAGE_REPOSITORY=in_memory` demo mode is non-functional the
   moment CP6/7 controllers exist.
2. **M2** — production `apiBaseUrl` double-prefixes `/api`
   (`/api/api/v1/messages`), a guaranteed 404 in any real deployment; trivial
   one-line fix, high blast radius if missed until Bonus 2.
3. **M1** — `SameSite=:lax` on the identity cookie silently breaks
   session scoping the instant frontend/backend are cross-domain, which is
   the exact Bonus-2 deployment scenario the HLD calls out; needs an
   env-gated `same_site: :none, secure: true` path before any live deploy.

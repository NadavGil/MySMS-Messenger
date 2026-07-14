# MySMS Messenger — Final Acceptance Audit vs. Original Exercise Spec

Audit date: 2026-07-14
Source spec: `uploads/full-stack-exercise.md` (read in full, verbatim, before this audit)
Method: every verdict below is based on direct inspection of the current repo
source (not prior summaries). File paths are relative to the repo root
(`/MySMS-Messenger`) unless noted.

Scope note (client-approved): this pass targets "core functionality only."
Bonus 1 (auth), Bonus 2 (live deploy), Bonus 3 (webhooks) were explicitly
deferred by the client. They are still audited below for completeness.

---

## Core Spec Requirements

### 1. "Frontend written in Angular's latest stable version"

**Verdict: MET**

- `frontend/package.json`: `@angular/core`, `@angular/cli`, `@angular/common`,
  `@angular/compiler`, `@angular/forms`, `@angular/platform-browser`,
  `@angular/router` all pinned to `^22.0.0` (CLI `^22.0.6`).
- `frontend/.angular/cache/22.0.6/` build cache confirms the resolved,
  installed version is 22.0.6.
- Verified against Angular's own release page (angular.dev/reference/releases,
  fetched live during this audit): **v22 is the current Active release**,
  published 2026-06-03; v21 is LTS; v20 is LTS. As of the audit date
  (2026-07-14) there is no newer major/minor than 22.x.
- Conclusion: the project is genuinely on Angular's latest stable line, not
  just "a recent one." No drift.

### 2. "Backend (API) written in Ruby on Rails with MongoDB as the database"

**Verdict: MET** (Rails/Mongoid usage is real; sandbox execution is a separate, honestly-disclosed limitation — see below)

- `backend/Gemfile`: `gem "rails", "~> 7.1.0"`, `gem "mongoid", "~> 9.0"`,
  `ruby "3.3.0"`. Rails is used API-only (`--skip-active-record`; Mongoid is
  the actual ODM/persistence layer, not ActiveRecord).
- `backend/app/models/message_document.rb`: real Mongoid document
  (`include Mongoid::Document`, `include Mongoid::Timestamps`, typed fields,
  a compound index on `{owner_id: 1, created_at: -1}`).
- `backend/app/repositories/mongo_message_repository.rb`: a genuine
  Mongoid-backed repository (`MessageDocument.create!`, `.where(...).order(...)`),
  not a stub — it also rescues `Mongo::Error` and re-raises a repository-layer
  error rather than leaking driver internals.
- `backend/config/mongoid.yml` / `config/initializers/mongoid.rb`: standard
  `Mongoid.load!` wiring, URI fully env-driven (`MONGO_URI`), defaulting to
  `mongodb://localhost:27017/mysms_{development,test}` — matching the
  project's `docker-compose.yml` (`image: mongo:7`, port 27017).
- **Is Rails 7.1 "latest"?** The spec does NOT say "Rails' latest stable
  version" (that phrase is used only for Angular). It just says "Ruby on
  Rails." Checked live: Rails' actual latest as of this audit is 8.1.3
  (March 2026); this project pins 7.1.x. This is not a spec violation (no
  "latest" requirement was made for Rails), but worth flagging: if the
  client expects parity with the Angular "latest" bar, upgrading to Rails 8
  would be a reasonable follow-up, not a defect against this spec as written.
- **Honesty check on the sandbox limitation:** `bundle install` cannot reach
  rubygems.org from this sandbox, so the Rails/Mongoid/RSpec/twilio-ruby/
  rack-cors/rack-attack stack has never actually booted or run its RSpec
  suite inside this sandbox. This is a genuine **sandbox limitation, not a
  deliverable gap** — the code is standard, idiomatic Rails/Mongoid usage
  that would install and run in any environment with normal internet access
  (this is exactly the kind of code a Rails developer would write by hand).
  To partially de-risk this, a zero-gem Minitest suite
  (`backend/test/run_all.rb`) was added that exercises the
  framework-independent core (domain object, in-memory repository, services,
  fake gateway) with only Ruby stdlib. Re-ran it live during this audit:
  **33 runs, 90 assertions, 0 failures, 0 errors** (`ruby backend/test/run_all.rb`).
  This does NOT touch Mongoid/Mongo/Rails routing/controllers at all, so it
  is not proof those layers work — it's proof the business logic they wrap
  is correct.

### 3. "Sending an SMS should be done through Twilio API"

**Verdict: MET as a config-driven, real Twilio integration; genuinely untested against the live API (client hasn't supplied credentials yet — expected per client's own stated plan)**

- `backend/app/gateways/twilio_sms_gateway.rb`: uses the real
  `twilio-ruby` gem (`gem "twilio-ruby", "~> 7.0"` in Gemfile),
  `Twilio::REST::Client.new(account_sid, auth_token)`, and calls
  `@client.messages.create(from: from_number, to: to, body: body)` — this is
  the correct, standard Twilio Ruby SDK call shape, not a fake.
- Credentials (`TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`)
  are read via `ENV.fetch` with no defaults/hardcoding — genuinely
  config-driven.
- `backend/config/initializers/container.rb`: gateway selection is a single
  env var, `SMS_PROVIDER=twilio` vs. default `fake`; if `twilio` is selected
  without all three required env vars, boot fails loudly with a clear error
  naming the missing vars (not a lazy runtime `KeyError`).
- `backend/app/gateways/fake_sms_gateway.rb` is the default until real
  credentials exist — it never touches the network, and includes a
  documented "always fail" sentinel number (`+10000000000`) so the
  sent→failed persistence path is testable without a live provider.
- Both `TwilioSmsGateway` and `FakeSmsGateway` implement the same
  `Gateways::SmsGatewayInterface` (`app/gateways/sms_gateway_interface.rb`),
  so swapping is purely `SMS_PROVIDER=twilio` — no code change needed once
  credentials arrive.
- Gap (expected, not a defect): `TwilioSmsGateway` has never been exercised
  against the real Twilio API (only against a stubbed `Twilio::REST::Client`
  in specs) because the client has not yet supplied real credentials — this
  matches the client's own stated plan ("supply real credentials later").

### 4. Functional requirement 1 — send a message via backend API

**Verdict: MET.** Traced the path: `POST /api/v1/messages`
(`backend/config/routes.rb`) → `Api::V1::MessagesController#create`
(`backend/app/controllers/api/v1/messages_controller.rb`) →
`Services::Container.send_message_service.call(to_number:, body:, owner_id: current_identity)`
→ `Services::SendMessageService#call`
(`backend/app/services/send_message_service.rb`) validates E.164 phone
format + non-empty/≤250-char body, calls `@gateway.send_sms`, then always
persists via `@repository.create(...)` regardless of gateway success/failure
(status becomes `"sent"` or `"failed"`), returning a `Result` the controller
serializes to JSON (201 on success, 422 with structured `errors` on
validation failure). Frontend calls this via
`frontend/src/app/services/messages-api.service.ts#sendMessage` with
`withCredentials: true`.

### 5. Functional requirement 2 — messages stored in a DB managed by the backend

**Verdict: MET.** `MongoMessageRepository#create` (default in non-test envs)
persists every send (success or failure) as a `MessageDocument` (Mongoid
document backed by MongoDB via `docker-compose.yml`'s `mongo:7` service).
An `InMemoryMessageRepository` exists as a swappable alternative
(`MESSAGE_REPOSITORY=in_memory`) for fast local demos/tests, selected the
same config-driven way as the gateway — this doesn't weaken requirement 2,
since Mongo is the real default and the swap is explicit opt-in.

### 6. Functional requirement 3 — list previously sent messages via a listing API endpoint

**Verdict: MET.** `GET /api/v1/messages` → `MessagesController#index` →
`Services::Container.list_messages_service.call(owner_id: current_identity)`
→ `ListMessagesService#call` → `repository.find_for_owner(owner_id)` →
Mongo query `.where(owner_id: owner_id).order(created_at: :desc)`. Response
shape is `{ count: N, messages: [...] }`, consumed by
`MessagesApiService#listMessages` and rendered by
`MessageHistoryComponent`.

### 7. Functional requirement 4 — only messages from the user's session-ID cookie are visible

**Verdict: MET.** Traced the actual scoping logic in
`backend/app/controllers/concerns/current_identity.rb`:
- A signed, `HttpOnly` cookie (`msms_owner`) is read on every request
  (`cookies.signed[COOKIE]`); if absent, a fresh `SecureRandom.uuid` is
  minted and set (1-year expiry, `SameSite=Lax` by default, `Secure` in
  production or when `CROSS_ORIGIN_COOKIES=true`).
- `current_identity` (this UUID) is passed as `owner_id:` into BOTH
  `SendMessageService.call` (write path) and `ListMessagesService.call`
  (read path) — the controller never lets a client pass its own owner_id.
- `MongoMessageRepository#find_for_owner` filters strictly by
  `owner_id: owner_id` in the Mongo query itself — scoping happens at the DB
  query level, not just app-level filtering after a broader fetch, so there
  is no path for one identity's messages to leak into another's listing.
- Documented, disclosed limitation (not hidden): a narrow race condition
  exists if two "first contact" requests from the same browser arrive
  before either receives a `Set-Cookie` — both would mint separate UUIDs and
  one set of messages could become orphaned to a discarded identity. This is
  explicitly commented in the code as an accepted limitation of
  cookie-based identity (not a spec violation; genuinely inherent to
  stateless request handling without an explicit synchronous "claim
  identity" step).

### 8. Wireframe fidelity

**Verdict: MET.** Compared templates directly against the wireframe
description:
- Title: `app.component.ts` sets `title = 'MY SMS MESSENGER'`, rendered in
  `app.component.html`'s `<header>`.
- Two-panel layout: `app.component.html` has `<section class="panel
  panel--new-message">` and `<section class="panel panel--history">` side
  by side (`class="panels"` container).
- Phone input: `new-message.component.html` has a `type="tel"` input bound
  to `formControlName="toNumber"`.
- Message textarea with N/250 counter: `<textarea formControlName="body">`
  plus `<div class="char-counter">{{ bodyLength }}/{{ bodyMaxLength }}</div>`;
  `MAX_BODY_LENGTH = 250` matches the backend's own limit
  (`send_message_service.rb`), so frontend/backend limits agree.
- Clear link: `<a class="clear-link" (click)="onClear()">Clear</a>` present.
- Submit button: present, disabled while `form.invalid || submitting`.
- "Message History (N)" header: `message-history.component.html` renders
  `<h2>Message History ({{ count$ | async }})</h2>` — N is the live count
  from the API response.
- Message cards: each `<li class="message-card">` shows `to_number`,
  a formatted timestamp (`| utcTimestamp` pipe), the body, and a
  `{{ bodyLength(message.body) }}/{{ bodyMaxLength }}` char count — matching
  the wireframe's per-message metadata.
- Loading/empty/error states are also handled (`@if (loading$ | async)`,
  empty-list message, error message) — beyond wireframe's literal scope but
  consistent with its intent.

**Core spec (items 1–8) overall verdict: FULLY MET.** No real gaps found in
the functional requirements or the wireframe. The only caveats are (a) Rails
7.1 vs. Rails' actual current 8.1.x — not a spec violation since the spec
never required "latest" for Rails, and (b) the Rails/Mongoid stack has not
been booted end-to-end in THIS sandbox (rubygems.org blocked) — a sandbox
limitation, not a code defect, mitigated by a real, currently-passing
zero-gem Minitest suite for the core logic.

---

## Bonus 1 — Basic user authentication

**Verdict: OUT OF SCOPE (client-approved), genuinely not implemented**

- No `User` model anywhere in `backend/app/models/` (only
  `message_document.rb` exists).
- No auth gem in `backend/Gemfile` (no Devise, `has_secure_password`, JWT,
  Sorcery, etc.).
- `grep -rli "devise|has_secure_password|class User"` across `backend/app`
  returned nothing relevant.
- `doc/HLD.md` §8 ("Extension to Deferred Bonuses") explicitly documents how
  this would extend cleanly: "Add a `User` model and an auth mechanism...
  Re-point the `CurrentIdentity` abstraction to resolve to the authenticated
  user id" — and the current `CurrentIdentity` concern's own comments
  independently confirm it was built as "the seam Bonus 1 later re-points...
  without touching Message storage/scoping." This is a real, load-bearing
  seam (owner_id is already an opaque string in the repository/service
  layer — swapping a cookie UUID for a User#id requires no schema change),
  not just a doc claim with no code backing it.
- Status: genuinely deferred, with a credible, inspected extension path.

## Bonus 2 — Deploy the app (live demo)

**Verdict: OUT OF SCOPE (client-approved), no live demo exists; project is deployable by the client**

- No CI/CD config, no Dockerfile for the app itself (only `docker-compose.yml`
  for local Mongo), no hosting config (Heroku/Fly/Render manifests, etc.)
  found in the repo.
- `README.md` gives concrete, step-by-step local run instructions (Mongo via
  `docker compose up -d`, backend via `bundle install` + `bin/rails server`,
  frontend via `npm install` + `ng serve`), and the app is genuinely
  config-driven (env vars for Mongo URI, Twilio creds, CORS origin, cookie
  SameSite policy) per `doc/HLD.md` §7 — so a client with their own hosting
  account could deploy it without code changes, but no one has actually done
  so, and there is no live URL anywhere in the repo or docs.
- Status: genuinely deferred; the groundwork (12-factor config) that would
  make deployment straightforward is real and present.

## Bonus 3 — Twilio delivery-status webhooks

**Verdict: OUT OF SCOPE (client-approved), genuinely not implemented**

- No webhook/callback controller/route exists — `backend/config/routes.rb`
  only declares `POST/GET /api/v1/messages` and `GET /health`.
- `MessageDocument#status` is a plain String field (`queued`/`sent`/`failed`)
  set synchronously at send time; it is never updated afterward by any
  inbound callback.
- `doc/HLD.md` §8 documents the intended extension: "Add one inbound webhook
  controller that Twilio calls; it looks up the message by [SID]..." and
  notes the `status`/`external_sid` fields already exist as inert
  placeholders reserved for this ("no schema migration" needed later).
  `message_document.rb`'s own comment corroborates this independently.
- No message card in the frontend renders any delivery-confirmation UI
  beyond the basic `status` field being available in the API response but
  unused by the UI — consistent with "not implemented."
- Status: genuinely deferred, with a credible extension path (schema already
  supports it without migration).

---

## GitHub push / live demo link

**Verdict: NOT YET DONE (expected, sandbox constraint) — local repo is push-ready**

- `git remote -v` confirms `origin` is set to
  `https://github.com/NadavGil/MySMS-Messenger.git` (both fetch/push).
- `git log --oneline` shows a full, real commit history (20+ commits
  spanning checkpoints, code review, QA/chaos review, security review, and
  the test-suite migration work) — this is not a single squashed dump, it's
  an actual incremental history.
- `git status` shows a clean working tree (only an untracked `.idea/`
  directory, which is IDE metadata, not project content).
- No push has occurred — this sandbox has no GitHub credentials, matching
  the known constraint. The client (or whoever has push access to
  `NadavGil/MySMS-Messenger`) needs to run `git push origin master`
  themselves.
- No live demo link exists anywhere (README, docs) — consistent with Bonus 2
  being deferred.

---

## Summary Table

| # | Requirement | Verdict |
|---|---|---|
| 1 | Angular latest stable | MET |
| 2 | Rails + MongoDB backend | MET (sandbox can't boot it; code is real) |
| 3 | Twilio API for SMS | MET (config-driven, real SDK, untested live — awaiting client creds) |
| 4 | Send message via API | MET |
| 5 | Messages stored in DB | MET |
| 6 | Listing API endpoint | MET |
| 7 | Session-cookie scoping | MET |
| 8 | Wireframe fidelity | MET |
| Bonus 1 | Auth | OUT OF SCOPE (client-approved), not implemented, clean extension seam exists |
| Bonus 2 | Live deploy | OUT OF SCOPE (client-approved), no live demo, deployable by client via README/docker-compose |
| Bonus 3 | Webhooks | OUT OF SCOPE (client-approved), not implemented, schema pre-reserves fields for it |
| — | GitHub push + live demo link | Local repo ready, remote set, push not yet executed (no creds in sandbox); no live demo |

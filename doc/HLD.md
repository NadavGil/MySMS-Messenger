# MySMS Messenger — High-Level Design (HLD)

| | |
|---|---|
| **Project** | MySMS Messenger |
| **Client** | CityHive (Director: Nadav Gilron) |
| **Author** | Solutions Architect |
| **Status** | Draft for Tech Lead hand-off |
| **Document type** | High-Level Design (architecture only — no application code) |

---

## 1. Overview & Goals

MySMS Messenger is a full-stack web application that lets an **authenticated
user** send SMS messages and review the history of messages they have
previously sent. Users sign up and log in with a username + password; their
message history follows their account rather than a browser session. The
application is composed of an **Angular** single-page app (SPA), a **Ruby on
Rails** JSON API, a **MongoDB** datastore, and an outbound integration with
**Twilio** for SMS delivery.

### Primary goals

1. **Authenticate** users via username + password: sign up, log in, log out.
2. **Send** an SMS message through the backend API to an arbitrary phone number.
3. **Persist** every sent message in the database.
4. **List** previously sent messages via a dedicated listing API endpoint.
5. **Scope** the listing so a user sees only the messages associated with their
   own authenticated account.

### Architectural goals (the "how")

- **Swappable SMS provider.** The act of sending an SMS sits behind an interface
  so a stub gateway is used in dev/test and the real Twilio adapter is wired in
  by configuration alone — no code change.
- **Swappable datastore.** All persistence goes through a Data Access Layer
  (repository) abstraction so MongoDB can be relocated (local Docker → Atlas →
  another Mongo) or replaced entirely with config-only changes.
- **Testability as a first-class concern.** Both the SMS gateway and the DAL are
  dependency-injected/interface-based so unit tests substitute fakes without
  touching network or database.
- **Clean extension path.** The remaining deferred bonus features (cloud deploy,
  delivery-status webhooks) can be added later without reworking the core. The
  identity abstraction built in the previous pass is being cashed in now to add
  real authentication (Bonus 1) with no change to Message storage or scoping.

---

## 2. Scope & Non-Goals

### In scope (this pass)

- **Real user authentication** (Bonus 1): sign up, log in, and log out with a
  username + password. Identity is a persisted `User`, not an anonymous session.
- Single-page UI matching the wireframe: "MY SMS MESSENGER" with a **New
  Message** panel (phone input, 250-char message box + live counter, Clear,
  Submit) and a **Message History (N)** panel (scrollable list; each item shows
  destination number, timestamp, bordered message body, and char count), plus
  login/signup/logout affordances.
- `POST` send endpoint and `GET` listing endpoint on the Rails API.
- Signup, login, and logout endpoints on the Rails API.
- Message persistence in MongoDB.
- Per-**user** ownership/scoping of the message list.
- Outbound SMS via a swappable gateway abstraction (stub now, Twilio later).
- Local MongoDB via `docker-compose`.

### Explicitly deferred (intentional non-goals for this pass)

| # | Bonus feature | Deferred? | Design accommodates it via… |
|---|---|---|---|
| **Bonus 2** | Live cloud deployment | Yes | **12-factor / config-driven** design (§7): all endpoints, secrets, and DB URIs come from env vars; containerized components. |
| **Bonus 3** | Twilio delivery-status webhooks | Yes | The **`status` field placeholder** on the Message entity (§5) + the SMS Gateway seam (§4.4) that can later carry a callback URL and an inbound webhook controller. |

(**Bonus 1 — user authentication — is no longer deferred; it is in scope this
pass**, see §1/§2 above and §4.5.) These remaining bonuses are called out so the
Tech Lead builds seams — not implementations — for them now.

---

## 3. System Context

```
                 (1) HTTPS / JSON over fetch
  ┌──────────┐   + auth session cookie      ┌───────────────────────┐
  │ Browser  │ ───────────────────────────▶│  Angular SPA (static) │
  │ (user)   │◀─────────────────────────── │  served as assets     │
  └──────────┘                             └───────────┬───────────┘
                                                       │ (2) XHR / fetch
                                                       │     JSON + cookie
                                                       ▼
                                         ┌───────────────────────────┐
                                         │      Rails API (JSON)      │
                                         │  ┌──────────────────────┐  │
                                         │  │ Controllers          │  │
                                         │  │  ▼                   │  │
                                         │  │ Service / UseCase    │  │
                                         │  │  ├── DAL (repository) │──┼──▶ (3) MongoDB
                                         │  │  │   interface        │  │    (Docker / Atlas)
                                         │  │  └── SmsGateway        │──┼──▶ (4) Twilio API
                                         │  │      interface         │  │    (real adapter)
                                         │  └──────────────────────┘  │        or Stub (dev/test)
                                         └───────────────────────────┘
```

**Flows**

1. **Browser ⇄ Angular SPA** — the user interacts with the page; after login the
   SPA holds the auth session cookie (set by the API) and sends it on every
   request.
2. **Angular SPA ⇄ Rails API** — JSON requests: auth (signup/login/logout),
   `POST` to send, `GET` to list. Requests carry the auth cookie so the API can
   authenticate and scope results.
3. **Rails API ⇄ MongoDB** — all reads/writes go through the DAL abstraction,
   never Mongoid directly from controllers.
4. **Rails API → Twilio** — outbound SMS via the SMS Gateway abstraction; the
   concrete adapter (Twilio vs. Stub) is chosen by configuration.

---

## 4. Key Components & Responsibilities

### 4.1 Angular SPA (frontend)

- Renders the single-page UI per the wireframe (two side-by-side panels) plus
  login/signup views and a logout action.
- **New Message panel:** phone-number field, message textarea bound to a live
  `N/250` counter, a **Clear** action that resets the form, and **Submit** that
  calls the send API.
- **Message History (N) panel:** fetches and renders the scrollable list; the
  `(N)` header reflects the count; each row shows destination number, formatted
  UTC timestamp (e.g. `Sunday, 17-May-20 11:18:45 UTC`), the body in a bordered
  box, and a per-message `chars/250` count.
- Talks to a single API base URL taken from Angular environment config
  (config-driven; no hard-coded host).
- Sends requests with credentials enabled so the auth cookie round-trips.
- Redirects unauthenticated users to login; handles `401` responses by returning
  the user to the login view.
- Client-side validation (non-empty number, ≤250 chars) is a UX convenience;
  the server remains the source of truth.

### 4.2 Rails API layer (controllers)

- Exposes the JSON endpoints (§6), performs request validation, translates
  domain results into HTTP responses/status codes, and manages the auth session
  cookie.
- **Thin controllers**: no persistence, Twilio, or password logic inline. They
  delegate to a service/use-case object that receives its collaborators
  (repository, gateway, identity) via dependency injection.
- Reads the auth cookie, resolves it to the current `User`, and hands the
  resolved identity to the service layer. Rejects unauthenticated requests to
  protected endpoints with `401`.

### 4.3 Data Access Layer (repository abstraction)

- A `MessageRepository` **interface** defines the persistence contract
  (`create`, `find_for_owner`, etc.). Controllers/services depend on the
  interface, not on Mongoid.
- A `MongoMessageRepository` is the concrete implementation for this pass.
- **Why:** lets us (a) inject an in-memory fake for unit tests, and (b) relocate
  or replace the datastore with a config/wiring change only. The Mongo
  connection URI is read from an env var so local Docker → Atlas is config-only.

### 4.4 SMS Gateway abstraction

- An `SmsGateway` **interface** exposes a single conceptual operation:
  "send a message to a number and return a provider result".
- Concrete implementations:
  - **`StubSmsGateway`** — used in dev and tests; records the call, returns a
    deterministic fake result, sends nothing over the network. This unblocks the
    whole build while Twilio credentials are unavailable.
  - **`TwilioSmsGateway`** — the real adapter; reads account SID, auth token, and
    from-number from env vars.
- Selection is by configuration (env var such as `SMS_PROVIDER=stub|twilio`) so
  swapping providers is a wiring change, never a code change. This is the IoC
  seam the Tech Lead will formalize.

### 4.5 Authenticated identity concept

- A `CurrentIdentity` abstraction answers one question: **"who owns this
  request?"** In this pass it resolves to an authenticated **`User`**: the API
  reads a signed, HttpOnly cookie that carries the logged-in user's id and loads
  the corresponding `User`.
- The delivery mechanism to the browser is unchanged from the previous pass — a
  signed, HttpOnly cookie — **only what it identifies changes**: a real `User`
  id instead of a random, anonymous session UUID. No anonymous identity is ever
  minted; a request without a valid authenticated identity is rejected (`401`).
- The service layer stores this `User` id on each Message and filters the
  listing by it — this is what enforces requirement (5), per-user scoping.
- **Authentication mechanism (per exercise instruction — use a built-in/
  well-known mechanism, never hand-rolled):** use Rails/ActiveModel's
  **`has_secure_password`** (bcrypt-backed). It ships in Rails core (not a
  third-party gem needing separate vetting) and is the natural fit for an
  **API-only** app with no server-rendered forms. A full framework such as
  Devise is more than this needs and is harder to bolt onto API-only + Mongoid
  cleanly, so it is deliberately avoided.
- Because the rest of the system depends on `CurrentIdentity` — not on "the
  cookie" or "the session" directly — introducing the `User` was a change to
  *how identity is resolved*, not to how messages are stored or listed, exactly
  as the previous HLD promised.

---

## 5. Data Model Overview

Two entities this pass: **User** and **Message**.

### User

| Field | Type | Purpose |
|---|---|---|
| `id` | ObjectId / string | Primary key; this is the value used as a Message's `owner_id`. |
| `username` | string (unique) | Login identifier. |
| `password_digest` | string | Bcrypt hash produced by `has_secure_password`. **Never stores plaintext.** |
| `created_at` | timestamp (UTC) | Standard audit field. |
| `updated_at` | timestamp (UTC) | Standard audit field. |

Notes:
- `username` is uniquely indexed.
- No plaintext password is ever persisted, and the `password` virtual attribute
  is never logged (see §7.3).

### Message

| Field | Type | Purpose |
|---|---|---|
| `id` | ObjectId / string | Primary key. |
| `to_number` | string | Destination phone number. |
| `body` | string (≤250 chars) | Message text. |
| `owner_id` | string | The `CurrentIdentity` value — **now a real `User` id** (previously an anonymous session id). Same field, same type; **no schema migration needed**, exactly as this document previously promised. **The scoping key.** |
| `status` | string (enum) | Delivery status **placeholder** — e.g. `queued`/`sent`; defaults to a simple "submitted" value now. Reserved for Bonus 3 webhook updates. |
| `provider_message_id` | string, nullable | Reference returned by the gateway (Twilio SID later); enables future status correlation. |
| `created_at` | timestamp (UTC) | When the message was created; drives the history timestamp display. |
| `updated_at` | timestamp (UTC) | Standard audit field; future status updates touch this. |

Notes:
- `owner_id` is indexed to make the scoped listing query efficient.
- `owner_id` now references a `User` id; because it was already an opaque owner
  identifier, pointing it at a real user is a semantic change only — no field or
  index change.
- `status` and `provider_message_id` exist now but are inert; they let webhooks
  (Bonus 3) update records later with **no schema migration**.

---

## 6. API Surface (high level)

Detailed request/response schemas and concrete endpoint design are the Tech
Lead's responsibility. At the architecture level there are two authentication
endpoints and two message endpoints:

| Method | Path (indicative) | Purpose | Auth / Scoping |
|---|---|---|---|
| `POST` | `/api/signup` | Create a `User` (username + password); persist a bcrypt `password_digest`. | Public. |
| `POST` | `/api/login` | Authenticate username + password; on success issue the signed, HttpOnly auth cookie. | Public; rate-limited (§7.3). |
| `DELETE` | `/api/logout` (or `POST`) | End the session; clear the auth cookie. | Requires authentication. |
| `POST` | `/api/messages` | Send an SMS: validate input, invoke the SMS Gateway, persist the resulting Message. | **Requires auth**; stamps the new record with the current user id. |
| `GET` | `/api/messages` | List previously sent messages for the history panel (typically newest-first). | **Requires auth**; returns **only** records whose `owner_id` matches the current user. |

- The two message endpoints now **require authentication**: an unauthenticated
  request receives `401` instead of the API silently minting an anonymous
  identity.
- Responses are JSON. Standard HTTP status codes convey success/validation/error.

---

## 7. Non-Functional Requirements

### 7.1 Testability (first-class)

- The **DAL** and **SMS Gateway** are interface-based and dependency-injected, so
  unit and service tests run against in-memory/stub collaborators — no live
  database or network, fast and deterministic.
- Thin controllers + a service/use-case layer keep business logic in plain,
  easily unit-testable objects.
- The Stub SMS gateway means the full send flow is testable today without Twilio
  credentials.
- Authentication is testable through the same seams: the identity resolution is
  a collaborator, and `has_secure_password` behavior is standard, well-covered
  Rails core.

### 7.2 Config-driven environment (12-factor)

- All environment-specific values — Mongo URI, SMS provider selection, Twilio
  credentials, API base URL, allowed CORS origins, cookie/signing secret — come
  from environment variables, never hard-coded. This is what makes
  datastore/provider swaps and future deployment config-only.
- Local MongoDB runs via `docker-compose`; the app reads the same `MONGO_URI`
  variable regardless of whether Mongo is local Docker or Atlas.

### 7.3 Security posture

- **Password hashing:** passwords are hashed with **bcrypt** via
  `has_secure_password`; plaintext passwords are **never stored** and **never
  logged** (filter the `password`/`password_confirmation` params from logs).
- **Brute-force protection on login:** the login endpoint is rate-limited by
  **extending the existing rack-attack approach** already used for the send-SMS
  endpoint (e.g. throttle by IP and by username) to blunt credential-stuffing.
- **Authentication required:** all existing message endpoints now require a
  valid authenticated identity and return `401` when absent — no anonymous
  identity is ever minted.
- Auth session cookie is **signed/HttpOnly** and, in deployed environments,
  `Secure` + appropriate `SameSite`.
- **CORS** restricted to the known SPA origin(s) via config.
- Server-side input validation (phone format, ≤250 chars, username/password
  rules) — client validation is UX only.
- Secrets (Twilio credentials, cookie signing key) are never committed; supplied
  via env vars.
- Scoping by `owner_id` (now a `User` id) prevents one user from reading
  another user's messages.

### 7.4 Scalability

- The Rails API is **stateless** apart from the auth cookie, so it scales
  horizontally behind a load balancer.
- `owner_id` is indexed for efficient scoped listing; listing can adopt
  pagination if history grows large.
- Outbound SMS is synchronous now; the gateway seam allows moving sends to a
  background job/queue later without changing callers.
- MongoDB scaling (replica set / Atlas tier) is an infrastructure/config concern,
  isolated behind the DAL.

---

## 8. Extension to Remaining Deferred Bonuses (without major rework)

> Bonus 1 (user authentication) is now implemented in this pass — see §4.5, §5,
> §6, §7.3. The two bonuses below remain deferred.

### Bonus 2 — Live cloud deployment

- Components are already containerizable (Angular static build, Rails API image,
  Mongo container/Atlas).
- Because everything is config-driven (§7.2), deploying means providing
  production env values (Mongo URI → Atlas, `SMS_PROVIDER=twilio` + credentials,
  CORS origin, secure cookie flags, cookie signing secret) — not code changes.
- CI/CD can build the two images and deploy behind a load balancer.

### Bonus 3 — Twilio delivery-status webhooks

- The Message entity already has `status` and `provider_message_id` placeholders.
- When sending, pass a status-callback URL to the `TwilioSmsGateway`.
- Add one inbound webhook controller that Twilio calls; it looks up the message by
  `provider_message_id` (via the repository) and updates `status`.
- No change to the send/list flows or the data shape — the seams already exist.

---

## 9. Risks, Open Questions & Assumptions

### Assumptions

- Identity = an authenticated `User` (username + password); message history
  follows the account and is now available across devices/browsers after login.
- Twilio credentials are unavailable now; the **Stub gateway is the default** and
  the app is fully demonstrable end-to-end without real SMS delivery.
- 250-character limit applies to the message body and is enforced server-side.
- Timestamps are stored and displayed in UTC (matching the wireframe format).
- "Latest stable" Angular and a current Rails API-only app are the target
  runtimes.

### Open questions (for client / Tech Lead)

- Password policy: minimum length/complexity, and any username format rules?
- Session lifetime / expiry: how long should a login remain valid; any
  "remember me" behavior?
- Should the `POST` persist a message even if the gateway send fails, or only on
  success? (Affects how `status` is initialized.)
- Any phone-number format/validation rules or country constraints?
- Expected history volume — is pagination needed in this pass or deferred?
- Should the history list auto-refresh after a send, or is optimistic
  client-side append acceptable?
- Rate-limiting thresholds for both login and the send-SMS endpoint.

### Risks

- **Twilio integration untested** until credentials arrive — mitigated by the
  gateway seam, but the real adapter must be integration-tested before any live
  use (SMS incurs cost and has deliverability nuances).
- **Cost/abuse exposure** once real sending is enabled — mitigated by
  authentication (now in scope) plus rate limiting on send.
- **Pre-existing anonymous messages** created before this change carry an
  `owner_id` that is a session UUID rather than a real `User` id, so they will
  not be visible to any account. This is a **known one-time data consideration**;
  because the app is **pre-launch** it is accepted as-is and **not** something to
  resolve retroactively (any such records can simply be discarded when the store
  is reset). No migration is planned.

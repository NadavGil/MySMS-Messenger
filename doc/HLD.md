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

MySMS Messenger is a full-stack web application that lets a user send SMS
messages and review the history of messages they have previously sent from the
same browser session. The application is composed of an **Angular** single-page
app (SPA), a **Ruby on Rails** JSON API, a **MongoDB** datastore, and an
outbound integration with **Twilio** for SMS delivery.

### Primary goals

1. **Send** an SMS message through the backend API to an arbitrary phone number.
2. **Persist** every sent message in the database.
3. **List** previously sent messages via a dedicated listing API endpoint.
4. **Scope** the listing so a user sees only the messages associated with their
   own browser session (session-cookie based; no login in this pass).

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
- **Clean extension path.** The deferred bonus features (auth, cloud deploy,
  delivery-status webhooks) can be added later without reworking the core.

---

## 2. Scope & Non-Goals

### In scope (this pass)

- Single-page UI matching the wireframe: "MY SMS MESSENGER" with a **New
  Message** panel (phone input, 250-char message box + live counter, Clear,
  Submit) and a **Message History (N)** panel (scrollable list; each item shows
  destination number, timestamp, bordered message body, and char count).
- `POST` send endpoint and `GET` listing endpoint on the Rails API.
- Message persistence in MongoDB.
- Session-cookie–based ownership/scoping of the message list.
- Outbound SMS via a swappable gateway abstraction (stub now, Twilio later).
- Local MongoDB via `docker-compose`.

### Explicitly deferred (intentional non-goals for this pass)

| # | Bonus feature | Deferred? | Design accommodates it via… |
|---|---|---|---|
| **Bonus 1** | User authentication / login | Yes | The **Identity abstraction** (§4.5): a `CurrentIdentity` concept that today resolves to a session cookie and later resolves to a `User`. |
| **Bonus 2** | Live cloud deployment | Yes | **12-factor / config-driven** design (§7): all endpoints, secrets, and DB URIs come from env vars; containerized components. |
| **Bonus 3** | Twilio delivery-status webhooks | Yes | The **`status` field placeholder** on the Message entity (§5) + the SMS Gateway seam (§4.4) that can later carry a callback URL and an inbound webhook controller. |

These are called out so the Tech Lead builds seams — not implementations — for
them now.

---

## 3. System Context

```
                 (1) HTTPS / JSON over fetch
  ┌──────────┐   + session cookie          ┌───────────────────────┐
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

1. **Browser ⇄ Angular SPA** — the user interacts with the page; the SPA holds
   the session cookie (set by the API) and sends it on every request.
2. **Angular SPA ⇄ Rails API** — JSON requests: `POST` to send, `GET` to list.
   Requests carry the session cookie so the API can scope results.
3. **Rails API ⇄ MongoDB** — all reads/writes go through the DAL abstraction,
   never Mongoid directly from controllers.
4. **Rails API → Twilio** — outbound SMS via the SMS Gateway abstraction; the
   concrete adapter (Twilio vs. Stub) is chosen by configuration.

---

## 4. Key Components & Responsibilities

### 4.1 Angular SPA (frontend)

- Renders the single-page UI per the wireframe (two side-by-side panels).
- **New Message panel:** phone-number field, message textarea bound to a live
  `N/250` counter, a **Clear** action that resets the form, and **Submit** that
  calls the send API.
- **Message History (N) panel:** fetches and renders the scrollable list; the
  `(N)` header reflects the count; each row shows destination number, formatted
  UTC timestamp (e.g. `Sunday, 17-May-20 11:18:45 UTC`), the body in a bordered
  box, and a per-message `chars/250` count.
- Talks to a single API base URL taken from Angular environment config
  (config-driven; no hard-coded host).
- Sends requests with credentials enabled so the session cookie round-trips.
- Client-side validation (non-empty number, ≤250 chars) is a UX convenience;
  the server remains the source of truth.

### 4.2 Rails API layer (controllers)

- Exposes the JSON endpoints (§6), performs request validation, translates
  domain results into HTTP responses/status codes, and manages the session
  cookie.
- **Thin controllers**: no persistence or Twilio logic inline. They delegate to
  a service/use-case object that receives its collaborators (repository, gateway,
  identity) via dependency injection.
- Establishes/reads the session cookie and hands the resolved identity to the
  service layer.

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

### 4.5 Session / Identity concept

- A `CurrentIdentity` abstraction answers one question: **"who owns this
  request?"** In this pass it is derived from a signed session cookie (a stable
  per-browser identifier issued on first contact).
- The service layer stores this identifier on each Message and filters the
  listing by it — this is what enforces requirement (4), per-session scoping.
- **Extension seam:** the same abstraction can later resolve to an authenticated
  `User` id (Bonus 1). Because the rest of the system depends on
  `CurrentIdentity` — not on "the cookie" directly — adding login becomes a matter
  of changing how identity is resolved, not how messages are stored or listed.

---

## 5. Data Model Overview

Single primary entity for this pass: **Message**.

| Field | Type | Purpose |
|---|---|---|
| `id` | ObjectId / string | Primary key. |
| `to_number` | string | Destination phone number. |
| `body` | string (≤250 chars) | Message text. |
| `owner_id` | string | The `CurrentIdentity` value (session id now; user id later). **The scoping key.** |
| `status` | string (enum) | Delivery status **placeholder** — e.g. `queued`/`sent`; defaults to a simple "submitted" value now. Reserved for Bonus 3 webhook updates. |
| `provider_message_id` | string, nullable | Reference returned by the gateway (Twilio SID later); enables future status correlation. |
| `created_at` | timestamp (UTC) | When the message was created; drives the history timestamp display. |
| `updated_at` | timestamp (UTC) | Standard audit field; future status updates touch this. |

Notes:
- `owner_id` is indexed to make the scoped listing query efficient.
- `status` and `provider_message_id` exist now but are inert; they let webhooks
  (Bonus 3) update records later with **no schema migration**.

---

## 6. API Surface (high level)

Detailed request/response schemas are the Tech Lead's responsibility. At the
architecture level there are two endpoints, both operating on the
session-scoped identity:

| Method | Path (indicative) | Purpose | Scoping |
|---|---|---|---|
| `POST` | `/api/messages` | Send an SMS: validate input, invoke the SMS Gateway, persist the resulting Message. | Stamps the new record with the current identity. |
| `GET` | `/api/messages` | List previously sent messages for the history panel (typically newest-first). | Returns **only** records whose `owner_id` matches the current identity. |

- Both endpoints require the session cookie; the API issues one on first request
  if absent.
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

### 7.2 Config-driven environment (12-factor)

- All environment-specific values — Mongo URI, SMS provider selection, Twilio
  credentials, API base URL, allowed CORS origins — come from environment
  variables, never hard-coded. This is what makes datastore/provider swaps and
  future deployment config-only.
- Local MongoDB runs via `docker-compose`; the app reads the same `MONGO_URI`
  variable regardless of whether Mongo is local Docker or Atlas.

### 7.3 Security posture (baseline for this pass)

- Session cookie is **signed/HttpOnly** and, in deployed environments, `Secure`
  + appropriate `SameSite`.
- **CORS** restricted to the known SPA origin(s) via config.
- Server-side input validation (phone format, ≤250 chars) — client validation is
  UX only.
- Secrets (Twilio credentials) are never committed; supplied via env vars.
- Scoping by `owner_id` prevents a session from reading another session's
  messages.
- *(Full auth/authorization is Bonus 1; see §8.)*

### 7.4 Scalability

- The Rails API is **stateless** apart from the session cookie, so it scales
  horizontally behind a load balancer.
- `owner_id` is indexed for efficient scoped listing; listing can adopt
  pagination if history grows large.
- Outbound SMS is synchronous now; the gateway seam allows moving sends to a
  background job/queue later without changing callers.
- MongoDB scaling (replica set / Atlas tier) is an infrastructure/config concern,
  isolated behind the DAL.

---

## 8. Extension to Deferred Bonuses (without major rework)

### Bonus 1 — User authentication / login

- Add a `User` model and an auth mechanism (e.g. token/session-backed login).
- Re-point the `CurrentIdentity` abstraction to resolve to the authenticated
  user id instead of the raw session id.
- Because every message already carries `owner_id` and all scoping goes through
  `CurrentIdentity`, **no change** is needed to the Message model, the repository,
  or the listing logic. A migration can optionally associate existing
  session-owned messages with users.

### Bonus 2 — Live cloud deployment

- Components are already containerizable (Angular static build, Rails API image,
  Mongo container/Atlas).
- Because everything is config-driven (§7.2), deploying means providing
  production env values (Mongo URI → Atlas, `SMS_PROVIDER=twilio` + credentials,
  CORS origin, secure cookie flags) — not code changes.
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

- No login in this pass; identity = signed session cookie, one logical "user"
  per browser session. Clearing cookies starts a fresh, empty history.
- Twilio credentials are unavailable now; the **Stub gateway is the default** and
  the app is fully demonstrable end-to-end without real SMS delivery.
- 250-character limit applies to the message body and is enforced server-side.
- Timestamps are stored and displayed in UTC (matching the wireframe format).
- "Latest stable" Angular and a current Rails API-only app are the target
  runtimes.

### Open questions (for client / Tech Lead)

- Should the `POST` persist a message even if the gateway send fails, or only on
  success? (Affects how `status` is initialized.)
- Any phone-number format/validation rules or country constraints?
- Expected history volume — is pagination needed in this pass or deferred?
- Should the history list auto-refresh after a send, or is optimistic
  client-side append acceptable?
- Rate-limiting expectations to guard against SMS-cost abuse (relevant once the
  real Twilio adapter is live).

### Risks

- **Twilio integration untested** until credentials arrive — mitigated by the
  gateway seam, but the real adapter must be integration-tested before any live
  use (SMS incurs cost and has deliverability nuances).
- **Cost/abuse exposure** once real sending is enabled — consider rate limiting
  and, eventually, auth (Bonus 1) before production.
- **Session-only identity** means no cross-device history and easy history loss
  on cookie clear — acceptable for this pass, resolved by Bonus 1.

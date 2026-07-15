# MySMS Messenger — Technical Design & Checkpoint Plan

| | |
|---|---|
| **Project** | MySMS Messenger |
| **Client** | CityHive (Director: Nadav Gilron) |
| **Author** | Tech Lead |
| **Status** | Ready for implementation |
| **Upstream** | Derived from `doc/HLD.md` (Solutions Architect) |
| **Audience** | Dev team — 1 senior backend, 1 junior backend, 1 senior frontend |

> This document turns the HLD's architecture into concrete, buildable
> instructions: exact file paths, class names, method signatures, folder layout,
> the HTTP contract, and an ordered checkpoint plan for parallel work.
> **No application code is written here** — but everything is specified so the
> devs can implement without further design decisions.

---

## 0. Decisions locked in this document (so devs don't re-litigate)

| Topic | Decision | Rationale |
|---|---|---|
| Rails version | **7.1.x** (latest stable 7.x), `--api` mode | API-only; no view/asset baggage. |
| Ruby version | **3.3.x** | Matches Rails 7.1 support window. |
| Persistence | **Mongoid document** wrapped behind a repository interface | HLD requires swappable DAL; the domain object we pass around is a plain value struct, not the Mongoid doc (see §3.4). |
| DI mechanism | **Plain-Rails container** resolved from `Rails.configuration.x` | No DI gem — keeps it idiomatic and reviewable. |
| Angular | **Standalone components** (Angular 17/18), no NgModule | Modern default; less boilerplate; matches "latest stable". |
| Frontend state | **Service + RxJS `BehaviorSubject`** store | NgRx is over-engineering for two panels. **Explicitly no NgRx.** |
| Testing | RSpec (backend) + Karma/Jasmine (frontend) | Standard, no CI required for this pass. |
| Persist-on-send-failure | Persist **always**; `status` reflects outcome (`sent`/`failed`) | Answers HLD open question; keeps history honest and supports webhook bonus. |
| Phone validation | **E.164** (`^\+[1-9]\d{1,14}$`), server-authoritative | Matches Twilio's expected format. |

---

## 1. Repository layout

```
MySMS-Messenger/
├── doc/
│   ├── HLD.md                 # architecture (Architect)
│   └── tech-design.md         # THIS document
├── backend/                   # Rails 7.1 API-only app
├── frontend/                  # Angular standalone SPA
├── docker-compose.yml         # local MongoDB (see §2.9)
├── .gitignore                 # already present
└── README.md                  # run instructions (added at CP10)
```

`backend/` and `frontend/` are currently empty and get scaffolded at CP1 / CP6.

---

## 2. Rails backend design

### 2.1 Bootstrap command (CP1)

```
cd backend
rails _7.1_ new . --api -T --skip-active-record
```

- `--api` → API-only middleware stack.
- `-T` → skip Minitest (we use RSpec).
- `--skip-active-record` → we use **Mongoid**, not ActiveRecord.

### 2.2 Gemfile additions

```ruby
gem "mongoid", "~> 9.0"          # MongoDB ODM
gem "twilio-ruby", "~> 7.0"      # real SMS gateway
gem "rack-cors"                  # CORS for Angular dev server

group :development, :test do
  gem "rspec-rails", "~> 6.1"
  gem "dotenv-rails"             # load .env locally
end

group :test do
  gem "rack-test"
end
```

### 2.3 Folder structure (backend/app)

```
backend/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   ├── concerns/
│   │   │   └── current_identity.rb            # §2.7
│   │   └── api/
│   │       └── v1/
│   │           ├── messages_controller.rb     # §2.8
│   │           └── health_controller.rb       # CP1 healthcheck
│   ├── models/
│   │   └── message_document.rb                # Mongoid doc, DAL-internal only (§3.4)
│   ├── domain/
│   │   └── message.rb                         # plain value object crossing layers
│   ├── repositories/
│   │   ├── message_repository_interface.rb    # contract (§3.1)
│   │   ├── mongo_message_repository.rb         # Mongo impl (§3.2)
│   │   └── in_memory_message_repository.rb     # test fake (§3.3)
│   ├── gateways/
│   │   ├── sms_gateway_interface.rb           # contract (§4.1)
│   │   ├── twilio_sms_gateway.rb              # real (§4.2)
│   │   └── fake_sms_gateway.rb                # dev/test (§4.3)
│   └── services/
│       ├── send_message_service.rb            # use-case (§5)
│       └── list_messages_service.rb
├── config/
│   ├── initializers/
│   │   ├── mongoid.rb / mongoid.yml           # §2.9
│   │   ├── container.rb                       # DI wiring (§2.6)
│   │   └── cors.rb                            # §2.10
│   ├── routes.rb                              # §2.8
│   └── application.rb
├── spec/
│   ├── requests/api/v1/messages_spec.rb       # contract tests (§7)
│   ├── repositories/*_spec.rb
│   ├── gateways/*_spec.rb
│   ├── services/*_spec.rb
│   └── support/{shared_examples,fakes}.rb
└── .env.example
```

### 2.4 Namespacing conventions

- Repositories live in module `Repositories::` (e.g. `Repositories::MongoMessageRepository`).
- Gateways live in module `Gateways::`.
- Services live in module `Services::`.
- Domain value object: `Domain::Message`.
- **CORRECTION (post-live-run audit — this section was wrong and caused a
  real bug):** this is *not* automatic. Rails adds every direct
  subdirectory of `app/` as its own Zeitwerk autoload root mapped to the
  **top-level** namespace by default — `app/repositories/mongo_message_repository.rb`
  autoloads as bare top-level `MongoMessageRepository`, not
  `Repositories::MongoMessageRepository`, unless told otherwise. This was
  only discovered once Rails could actually boot outside the sandbox that
  built this app (the sandbox's rubygems.org access was blocked the whole
  time, so Rails never booted there at all). `config/application.rb` now
  explicitly removes the default unnamespaced autoload roots for
  `app/domain`, `app/repositories`, `app/gateways`, `app/services` and
  re-registers each via `Rails.autoloaders.main.push_dir(dir, namespace:)`,
  which is the documented, correct way to get folder-name namespacing.

### 2.6 Inversion of Control — the container (initializer)

**No DI gem.** A single initializer resolves concrete classes from config, and
config is set from ENV with per-environment defaults. Services receive
collaborators via constructor injection; controllers ask the container for a
fully wired service.

`config/initializers/container.rb`:
```ruby
# Resolve the repository implementation.
repo_class = ENV.fetch("MESSAGE_REPOSITORY",
                       Rails.env.test? ? "in_memory" : "mongo")
Rails.configuration.x.message_repository_class =
  { "mongo"     => "Repositories::MongoMessageRepository",
    "in_memory" => "Repositories::InMemoryMessageRepository" }.fetch(repo_class)

# Resolve the SMS gateway implementation.
provider = ENV.fetch("SMS_PROVIDER",
                     Rails.env.test? ? "fake" : "fake") # default fake until Twilio creds exist
Rails.configuration.x.sms_gateway_class =
  { "twilio" => "Gateways::TwilioSmsGateway",
    "fake"   => "Gateways::FakeSmsGateway" }.fetch(provider)
```

A tiny factory (`app/services/container.rb`, module `Container`) turns those
class-name strings into instances so controllers stay one-liners:
```ruby
module Container
  module_function
  def message_repository
    Rails.configuration.x.message_repository_class.constantize.new
  end
  def sms_gateway
    Rails.configuration.x.sms_gateway_class.constantize.new
  end
  def send_message_service
    Services::SendMessageService.new(repository: message_repository, gateway: sms_gateway)
  end
  def list_messages_service
    Services::ListMessagesService.new(repository: message_repository)
  end
end
```

> **Swapping is config-only:** `MESSAGE_REPOSITORY=in_memory` or
> `SMS_PROVIDER=twilio` changes wiring with zero code edits. In specs we can also
> inject a fake directly into a service constructor for a single test.

### 2.7 Session / identity handling

Use Rails' built-in **signed cookie** (not full session middleware, since we're
API-only). A concern issues a stable random id on first contact and reads it
thereafter.

`app/controllers/concerns/current_identity.rb` — concern name **`CurrentIdentity`**:
```ruby
module CurrentIdentity
  extend ActiveSupport::Concern
  included { before_action :resolve_current_identity }

  private
  COOKIE = :msms_owner
  def resolve_current_identity
    @current_identity = cookies.signed[COOKIE]
    unless @current_identity.present?
      @current_identity = SecureRandom.uuid
      cookies.signed[COOKIE] = {
        value: @current_identity, httponly: true,
        same_site: :lax, secure: Rails.env.production?,
        expires: 1.year.from_now
      }
    end
  end
  attr_reader :current_identity
end
```
- API-only apps need cookies middleware enabled — add
  `config.middleware.use ActionDispatch::Cookies` in `application.rb` and set
  `config.middleware.use ActionDispatch::Session::CookieStore` is **not** needed
  (signed cookies work with `ActionDispatch::Cookies` + `secret_key_base`).
- `ApplicationController` includes `CurrentIdentity`; every API controller then
  has `current_identity`.

### 2.8 Routes & controllers

`config/routes.rb`:
```ruby
Rails.application.routes.draw do
  get "/health", to: "api/v1/health#show"
  namespace :api do
    namespace :v1 do
      resources :messages, only: [:create, :index]
    end
  end
end
```

`Api::V1::MessagesController` (thin):
```ruby
def create
  result = Container.send_message_service.call(
    to_number: params[:to_number], body: params[:body], owner_id: current_identity)
  if result.ok?
    render json: serialize(result.message), status: :created
  else
    render json: { errors: result.errors }, status: :unprocessable_entity
  end
end

def index
  messages = Container.list_messages_service.call(owner_id: current_identity)
  render json: { count: messages.size, messages: messages.map { serialize(_1) } }
end
```

### 2.9 MongoDB / Mongoid config

`config/mongoid.yml` reads the URI from ENV with a local default:
```yaml
development:
  clients:
    default:
      uri: <%= ENV.fetch("MONGO_URI", "mongodb://localhost:27017/mysms_development") %>
test:
  clients:
    default:
      uri: <%= ENV.fetch("MONGO_URI", "mongodb://localhost:27017/mysms_test") %>
production:
  clients:
    default:
      uri: <%= ENV.fetch("MONGO_URI") %>   # required in prod, no default
```

`docker-compose.yml` (repo root):
```yaml
services:
  mongo:
    image: mongo:7
    container_name: mysms_mongo
    ports:
      - "27017:27017"
    volumes:
      - mysms_mongo_data:/data/db
volumes:
  mysms_mongo_data:
```

### 2.10 CORS

`config/initializers/cors.rb` — allow the Angular dev server, credentials on:
```ruby
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("CORS_ORIGINS", "http://localhost:4200").split(",")
    resource "/api/*",
      headers: :any,
      methods: [:get, :post, :options],
      credentials: true       # required so the signed cookie round-trips
  end
end
```
> `credentials: true` means origins **cannot** be `*`; the Angular origin must be
> explicit. Frontend must set `withCredentials: true` (see §8.3).

---

## 3. Data Access Layer

### 3.1 `Repositories::MessageRepositoryInterface` (contract)

Ruby is duck-typed; we document the contract as a module with method stubs that
raise `NotImplementedError`, and both implementations `include` it (for intent)
or simply conform. Contract:

```ruby
module Repositories
  module MessageRepositoryInterface
    # @param attrs [Hash] to_number:, body:, owner_id:, status:, external_sid:
    # @return [Domain::Message] the persisted message (with id + created_at)
    def create(attrs); raise NotImplementedError; end

    # @param owner_id [String]
    # @return [Array<Domain::Message>] newest-first
    def find_for_owner(owner_id); raise NotImplementedError; end
  end
end
```

### 3.2 `Repositories::MongoMessageRepository`

- `include MessageRepositoryInterface`.
- `create` builds a `MessageDocument`, saves it, maps to `Domain::Message`.
- `find_for_owner` → `MessageDocument.where(owner_id:).order(created_at: :desc)`
  mapped to `Domain::Message`. Relies on the `owner_id` index (§3.4).

### 3.3 `Repositories::InMemoryMessageRepository` (test/dev fake)

- Backed by an `Array`; `create` assigns a UUID id + `Time.now.utc`, appends.
- `find_for_owner` filters by `owner_id`, returns reverse-chronological.
- Used by specs and by any run with `MESSAGE_REPOSITORY=in_memory` (fast demos).

### 3.4 Model & domain object

- **`MessageDocument`** (`app/models/message_document.rb`) — a `Mongoid::Document`,
  **only referenced inside `MongoMessageRepository`** (never from controllers/services):
  ```ruby
  class MessageDocument
    include Mongoid::Document
    include Mongoid::Timestamps          # created_at / updated_at (UTC)
    field :to_number,   type: String
    field :body,        type: String
    field :owner_id,    type: String
    field :status,      type: String, default: "queued"
    field :external_sid, type: String                 # Twilio SID (nullable)
    # delivered/undelivered are future webhook values — status stays String enum
    index({ owner_id: 1, created_at: -1 })
    STATUSES = %w[queued sent failed].freeze           # delivered/undelivered reserved
  end
  ```
- **`Domain::Message`** — a `Struct`/`Data` value object with
  `id, to_number, body, owner_id, status, external_sid, created_at`. This is what
  crosses the DAL boundary, so services/controllers never touch Mongoid. Keeps
  the datastore genuinely swappable.

---

## 4. SMS Gateway abstraction

### 4.1 `Gateways::SmsGatewayInterface`

```ruby
module Gateways
  module SmsGatewayInterface
    Result = Data.define(:success, :external_sid, :error)
    # @return [Result] success:Boolean, external_sid:String|nil, error:String|nil
    def send_sms(to:, body:); raise NotImplementedError; end
  end
end
```

### 4.2 `Gateways::TwilioSmsGateway`

- Reads `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` from ENV.
- Uses `twilio-ruby`: `client.messages.create(from:, to:, body:)`.
- Returns `Result.new(true, msg.sid, nil)` on success; rescues
  `Twilio::REST::RestError` → `Result.new(false, nil, e.message)`.
- **Untested against live Twilio this pass** (no creds) — documented at CP9.

### 4.3 `Gateways::FakeSmsGateway`

- Logs `"[FakeSmsGateway] to=… body=…"` via `Rails.logger`.
- Returns `Result.new(true, "FAKE-#{SecureRandom.hex(8)}", nil)`.
- Default in dev (when Twilio creds absent) and always in test.

---

## 5. Service layer (use-cases)

`Services::SendMessageService#call(to_number:, body:, owner_id:)`:
1. Validate `to_number` (E.164 regex) and `body` (present, ≤250). On failure
   return `Result(ok: false, errors: {...})` — **no gateway call, no persistence**.
2. Call `gateway.send_sms(to:, body:)`.
3. Map outcome → `status` (`"sent"` if success else `"failed"`), capture
   `external_sid`.
4. `repository.create(...)` — **persist regardless of send outcome** (locked
   decision §0).
5. Return `Result(ok: true, message: <Domain::Message>)`.

`Services::ListMessagesService#call(owner_id:)` → `repository.find_for_owner(owner_id)`.

Both are POROs with constructor-injected collaborators → unit-testable with fakes.

---

## 6. API contract (THE frontend/backend contract — see §9)

### 6.1 `POST /api/v1/messages`

Request JSON:
```json
{ "to_number": "+14155550123", "body": "Hello there" }
```
Validation:
- `to_number`: required, matches `^\+[1-9]\d{1,14}$` (E.164).
- `body`: required, 1–250 chars.

Success `201 Created`:
```json
{
  "id": "664f…",
  "to_number": "+14155550123",
  "body": "Hello there",
  "status": "sent",
  "external_sid": "FAKE-ab12cd34",
  "created_at": "2020-05-17T11:18:45Z"
}
```
Validation error `422 Unprocessable Entity`:
```json
{ "errors": { "to_number": ["is not a valid E.164 number"],
              "body": ["must be 250 characters or fewer"] } }
```

### 6.2 `GET /api/v1/messages`

Success `200 OK` — newest-first, scoped to `current_identity`, with `count`:
```json
{
  "count": 2,
  "messages": [
    { "id": "…", "to_number": "+1…", "body": "…", "status": "sent",
      "external_sid": "…", "created_at": "2020-05-17T11:18:45Z" },
    { "id": "…", "to_number": "+1…", "body": "…", "status": "sent",
      "external_sid": "…", "created_at": "2020-05-16T09:02:11Z" }
  ]
}
```
- `count` feeds the wireframe header **"Message History (N)"**.
- `created_at` is ISO-8601 UTC; frontend formats to the wireframe style
  (`Sunday, 17-May-20 11:18:45 UTC`).
- Both endpoints require the signed cookie; the API issues one on first request.

---

## 7. Backend testing strategy (RSpec)

- **Request specs** (`spec/requests/api/v1/messages_spec.rb`) — assert the §6
  contract: 201 shape, 422 validation, GET ordering/scoping/`count`. Run with
  `MESSAGE_REPOSITORY=in_memory` + `SMS_PROVIDER=fake` (test defaults) so **no
  Mongo/network** is required.
- **Repository specs** — a shared-example `"a message repository"` runs against
  both `InMemory` and (optionally, tagged `:mongo`) `Mongo` impls to prove
  contract parity. Mongo-tagged specs skipped unless Mongo is up.
- **Gateway specs** — `FakeSmsGateway` returns a fake sid; `TwilioSmsGateway`
  tested with a stubbed `Twilio::REST::Client` (no live calls).
- **Service specs** — inject fakes directly to prove send-failure still persists
  with `status: "failed"`, and validation short-circuits.
- Local run (no CI this pass): `cd backend && bundle exec rspec`. Green suite with
  zero external dependencies is the gate.

---

## 8. Angular frontend design

### 8.1 Bootstrap (CP6)

```
cd frontend
ng new mysms --standalone --routing=false --style=scss --skip-tests=false
```
Standalone components, no NgModule (locked §0). No router needed (single page).

### 8.2 Structure

```
frontend/src/app/
├── app.component.ts / .html / .scss      # shell: "MY SMS MESSENGER" header, two panels
├── components/
│   ├── new-message/
│   │   └── new-message.component.{ts,html,scss,spec.ts}
│   └── message-history/
│       └── message-history.component.{ts,html,scss,spec.ts}
├── services/
│   ├── messages-api.service.{ts,spec.ts}     # HttpClient wrapper
│   └── messages-store.service.ts             # RxJS BehaviorSubject store
├── models/
│   └── message.model.ts                      # TS interfaces mirroring §6
└── environments/environment*.ts              # apiBaseUrl (config-driven)
```
`main.ts` uses `bootstrapApplication(AppComponent, { providers: [provideHttpClient(withFetch())] })`.

### 8.3 `MessagesApiService`

```ts
sendMessage(payload: { to_number: string; body: string }): Observable<Message>
listMessages(): Observable<{ count: number; messages: Message[] }>
```
- All calls use `{ withCredentials: true }` so the signed session cookie
  round-trips (pairs with backend CORS `credentials: true`, §2.10).
- Base URL from `environment.apiBaseUrl` (`http://localhost:3000` in dev).

### 8.4 Components (match wireframe)

- **`NewMessageComponent`**: reactive form — phone `<input>`, message
  `<textarea>` with a live `{{ body.length }}/250` counter, **Clear** link
  (resets form), **Submit** button (disabled when invalid). On submit calls
  `api.sendMessage()` then tells the store to refresh history.
- **`MessageHistoryComponent`**: subscribes to store; header shows
  `Message History ({{ count }})`; each card shows to_number, formatted UTC
  timestamp, bordered body box, and per-message `{{ body.length }}/250`.
- **`AppComponent`**: shell with "MY SMS MESSENGER" header, lays out the two
  components side-by-side per wireframe.

### 8.5 State management (explicitly NOT NgRx)

`MessagesStoreService` holds `messages$ = new BehaviorSubject<Message[]>([])`
and `count$`. `NewMessageComponent` calls `store.refresh()` (which calls
`api.listMessages()`) after a successful send; `MessageHistoryComponent` renders
`store.messages$`. Simple, testable, no NgRx boilerplate.

### 8.6 Frontend testing (Karma/Jasmine)

- `MessagesApiService` spec uses **`HttpTestingController`** — assert URL, method,
  `withCredentials`, request body, and mapped response for both methods.
- Component specs: 250-char counter updates, Submit disabled on invalid input,
  Clear resets, history renders count + cards.
- **Definition of Done per story**: component/service has passing spec(s) covering
  its acceptance criteria; `ng test --watch=false` green; no console errors.

---

## 9. Backend ⇄ Frontend contract (parallelization)

**The §6 API contract IS the integration contract.** Once it is agreed (CP1
review), backend and frontend proceed in parallel:
- Frontend builds against the §6 JSON shapes using mocked `HttpTestingController`
  responses — it does **not** need a running backend.
- Backend builds/tests against the same shapes via request specs.
- Integration happens at CP10 (CORS + compose). Any change to §6 must be a
  reviewed edit to this doc, announced to both devs — no silent shape drift.

---

## 10. Checkpoint plan (one commit each)

| CP | Story title | Acceptance criteria | Role | Size |
|----|-------------|---------------------|------|------|
| **CP1** | Rails skeleton boots + healthcheck | `rails new --api`, boots, `GET /health` → `200 {"status":"ok"}`; RSpec installed, `bundle exec rspec` green | Senior BE | S |
| **CP2** | Mongo DAL: repository interface + InMemory fake + Message model | `MessageRepositoryInterface`, `InMemoryMessageRepository`, `MongoMessageRepository`, `MessageDocument`, `Domain::Message`; shared-example repo spec passes on InMemory | Senior BE | M |
| **CP3** | Container / IoC wiring | `container.rb` initializer + `Container` factory resolve repo & gateway from ENV; defaults correct per env; spec proves swap | Junior BE | S |
| **CP4** | SMS gateway interface + fake gateway | `SmsGatewayInterface`, `FakeSmsGateway` returns fake sid + logs; gateway spec green | Junior BE | S |
| **CP5** | Session identity concern | `CurrentIdentity` concern issues/reads signed cookie; request spec proves stable id across requests | Senior BE | S |
| **CP6** | POST /api/v1/messages end-to-end (fake gateway) | Validates E.164 + ≤250; persists always; 201 shape per §6.1; 422 shape; request spec green | Senior BE | M |
| **CP7** | GET /api/v1/messages with scoping | Newest-first, `count` field, scoped to `current_identity`; cross-session isolation proven in spec | Junior BE | M |
| **CP8** | Angular skeleton + shell layout | `ng new` standalone; `AppComponent` header + two-panel layout; `ng test` green | Senior FE | S |
| **CP9** | NewMessageComponent wired to API | Form + live 250 counter + Clear + Submit; `MessagesApiService.sendMessage` (`withCredentials`); HttpTestingController spec | Senior FE | M |
| **CP10** | MessageHistoryComponent wired to API | List with `(N)` header + cards (number/timestamp/body/counter); store refresh after send; spec green | Senior FE | M |
| **CP11** | Twilio real gateway behind config | `TwilioSmsGateway` reads ENV creds, uses twilio-ruby; selected by `SMS_PROVIDER=twilio`; stubbed-client spec; live path documented-untested | Senior BE | M |
| **CP12** | CORS + docker-compose + README | `rack-cors` for `:4200` w/ credentials; `docker-compose.yml` Mongo; README run steps; full local demo works end-to-end | Junior BE | S |

**Parallelization notes:** CP1 first (blocks all BE). After CP1, FE track
(CP8→9→10) runs fully in parallel with BE track (CP2→…). CP3/CP4 (junior) can
run alongside CP5 (senior). CP12 integrates both tracks last.

---

## 11. Environment variables (`.env.example`)

```
MONGO_URI=mongodb://localhost:27017/mysms_development
MESSAGE_REPOSITORY=mongo          # mongo | in_memory
SMS_PROVIDER=fake                 # fake | twilio
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=
CORS_ORIGINS=http://localhost:4200
```

---

## 12. Open questions / carry-over from HLD §9

- **Persist-on-failure**: resolved here (persist always). Confirm with client.
- **Phone format**: adopted E.164; confirm no country restriction.
- **Pagination**: deferred this pass (`find_for_owner` returns all); revisit if
  volume grows.
- **History refresh after send**: store `refresh()` re-fetches (server is source
  of truth) rather than optimistic append — simplest correct behavior.
- **Rate limiting**: out of scope until real Twilio is live (Bonus).

---

## 13. Bonus 1: Authentication (`has_secure_password`)

> Implements HLD §8 Bonus 1. Re-points the existing `CurrentIdentity` seam
> (§2.7) from a self-minted anonymous UUID to a **real authenticated `User`
> id**. **Decisions locked upstream (do not re-litigate):** use ActiveModel's
> built-in `has_secure_password` (bcrypt), NOT Devise; keep delivering identity
> via the SAME signed HttpOnly `:msms_owner` cookie already built and fought
> through for CORS/SameSite — only *what the cookie identifies* changes. No JWT,
> no token gem.

### 13.1 What does NOT change (promises kept)

- **`MessageDocument#owner_id` / `Domain::Message#owner_id`: ZERO schema
  changes.** Same `String` field, same `index({ owner_id: 1, created_at: -1 })`,
  same repository/service/serialize code. It is simply now populated with a real
  `User` id (`user.id.to_s`) instead of `SecureRandom.uuid`. `SendMessageService`,
  `ListMessagesService`, both repositories, and `MessagesController` need **no
  edits** — this is exactly the seam HLD §4.5/§8 promised.
- **Cookie infrastructure unchanged.** The `:msms_owner` signed HttpOnly cookie
  and *all* of `CurrentIdentity`'s existing `same_site_policy` / `secure_cookie?`
  / `cross_origin_cookies?` (`CROSS_ORIGIN_COOKIES` ENV) logic **carry over
  verbatim**. Same CORS `credentials: true`, same Angular `withCredentials: true`.
- **Container / IoC, gateways, DAL abstraction**: untouched.

### 13.2 `User` model (`app/models/user.rb`)

`app/models/` is a **default (unnamespaced) Zeitwerk autoload root** (unlike
`app/domain|repositories|gateways|services`, which §2.4/`application.rb`
re-namespace). So `app/models/user.rb` autoloads as top-level `::User` — the
exact same pattern as `MessageDocument`. No `application.rb` autoload change.

```ruby
class User
  include Mongoid::Document
  include Mongoid::Timestamps
  # If `has_secure_password` raises NoMethodError at boot, add explicitly:
  #   include ActiveModel::SecurePassword
  # (ActiveRecord auto-includes it; Mongoid versions vary. Confirm at CP13.)
  has_secure_password

  field :username,        type: String
  field :password_digest, type: String   # required by has_secure_password

  # Case policy (MY CALL): usernames are case-INSENSITIVE for identity but
  # stored in their normalized lowercase form. Normalize before validation so
  # both the unique index and login lookups are trivial exact matches.
  before_validation { self.username = username.downcase.strip if username.is_a?(String) }

  validates :username, presence: true,
                       uniqueness: true,      # app-level guard (racy; index is authoritative)
                       format: { with: /\A[a-z0-9_]{3,30}\z/,
                                 message: "must be 3-30 chars: lowercase letters, digits, underscore" }
  # has_secure_password already validates password presence on create and
  # enforces bcrypt's 72-byte max. Add a sane minimum:
  validates :password, length: { minimum: 8 }, allow_nil: true

  # Authoritative uniqueness guard (uniqueness validation alone is racy).
  index({ username: 1 }, { unique: true })
end
```

- **Gemfile**: bcrypt is **NOT currently present** (confirmed — Gemfile has
  rails/mongoid/twilio-ruby/rack-cors/rack-attack only). Add:
  `gem "bcrypt", "~> 3.1.20"`. Then `bundle install`.
- Create the unique index on deploy: `bin/rails db:mongoid:create_indexes`.

### 13.3 `CurrentIdentity` rework (`app/controllers/concerns/current_identity.rb`)

Replace "mint a UUID on first contact" with "require a real, still-existing
authenticated user; else 401". Add reusable `sign_in`/`sign_out` so cookie
writing stays in one place (reusing the untouched flag helpers).

```ruby
module CurrentIdentity
  extend ActiveSupport::Concern
  included { before_action :resolve_current_identity }

  private
  COOKIE = :msms_owner

  # Now REQUIRES a valid user id in the signed cookie. No silent identity minting.
  def resolve_current_identity
    user_id = cookies.signed[COOKIE]
    @current_user = User.where(id: user_id).first if user_id.present?
    return if @current_user   # authenticated

    render json: { errors: { base: ["Not authenticated"] } }, status: :unauthorized
  end

  attr_reader :current_user
  # Backwards-compatible alias: MessagesController still calls `current_identity`.
  def current_identity = @current_user&.id&.to_s

  # Called by AuthController on signup/login. Cookie contents = the User id
  # STRING (nothing else). All flag logic below is UNCHANGED from §2.7.
  def sign_in(user)
    @current_user = user
    cookies.signed[COOKIE] = {
      value: user.id.to_s, httponly: true,
      same_site: same_site_policy, secure: secure_cookie?,
      expires: 1.year.from_now
    }
  end

  def sign_out
    cookies.delete(COOKIE, same_site: same_site_policy, secure: secure_cookie?)
    @current_user = nil
  end

  # same_site_policy / secure_cookie? / cross_origin_cookies? : UNCHANGED (§2.7).
end
```

- `MessagesController` keeps calling `current_identity` (now the real user id
  string) — **no controller edit needed**; it just starts returning 401 for
  unauthenticated callers automatically (before_action halts).
- If the old anonymous UUID cookie is presented, `User.where(id: uuid)` misses →
  401 → forces (re)login. Correct and intended (see §13.9).

### 13.4 `AuthController` (`app/controllers/api/v1/auth_controller.rb`)

Inherits `ApplicationController` (so it gets `ActionController::Cookies`,
`wrap_parameters false`, `rescue_from RepositoryError`, and `CurrentIdentity`).
**Skip the auth gate for the endpoints that must work while unauthenticated:**

```ruby
module Api
  module V1
    class AuthController < ApplicationController
      # signup/login run BEFORE auth exists; logout is idempotent (never 401).
      # `me` intentionally does NOT skip — the before_action's 401 IS its
      # "not logged in" answer.
      skip_before_action :resolve_current_identity, only: %i[signup login logout]

      # POST /api/v1/auth/signup
      def signup
        user = User.new(username: params[:username], password: params[:password])
        if user.save
          sign_in(user)
          render json: user_json(user), status: :created
        else
          render json: { errors: user.errors.messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/auth/login
      def login
        user = User.where(username: params[:username].to_s.downcase.strip).first
        # user&.authenticate returns false for bad password / when user is nil.
        # Generic message on BOTH paths -> no username enumeration.
        if user&.authenticate(params[:password].to_s)
          sign_in(user)
          render json: user_json(user), status: :ok
        else
          render json: { errors: { base: ["Invalid username or password"] } },
                 status: :unauthorized
        end
      end

      # DELETE /api/v1/auth/logout
      def logout
        sign_out
        head :no_content
      end

      # GET /api/v1/auth/me  (before_action already 401s if unauthenticated)
      def me
        render json: user_json(current_user), status: :ok
      end

      private
      # NEVER expose password_digest.
      def user_json(user) = { id: user.id.to_s, username: user.username }
    end
  end
end
```

> **Enumeration/timing note:** `authenticate` runs a bcrypt compare only when the
> user exists, so a non-existent username returns faster. For this pre-launch app
> that timing delta is an accepted low risk; the rack-attack throttle (§13.6) is
> the primary brute-force control. If tightened later, do a dummy
> `BCrypt::Password.create` compare on the miss path to equalize timing.

### 13.5 Routes (`config/routes.rb` additions)

Add inside the existing `namespace :api / namespace :v1` block, alongside
`resources :messages`:

```ruby
post   "auth/signup", to: "auth#signup"
post   "auth/login",  to: "auth#login"
delete "auth/logout", to: "auth#logout"
get    "auth/me",     to: "auth#me"
```

**REQUIRED CORS CHANGE (`config/initializers/cors.rb`):** logout is `DELETE`,
which the current `methods: [:get, :post, :options]` does NOT allow. Change to
`methods: [:get, :post, :delete, :options]`. (Flagged — easy to miss.)

### 13.6 Rate limiting (`config/initializers/rack_attack.rb`)

Extend the existing `class Rack::Attack` (same `unless Rails.env.test? || ...`
guard, same JSON `throttled_responder`) with a login throttle:

```ruby
# Brute-force protection for POST /api/v1/auth/login.
throttle("auth/login/ip", limit: 5, period: 60) do |req|
  req.ip if req.post? && req.path == "/api/v1/auth/login"
end
```

- **Key = IP** (MY CALL): 5 attempts / 60s per IP. Simple and robust. Keying by
  `IP + attempted username` is attractive but the JSON body isn't parsed at
  middleware time — reading it requires `req.body.read` + `req.body.rewind`,
  which is fragile with the JSON parser downstream. IP-only is the pragmatic,
  correct-by-default choice; add the username discriminator later only if shared
  NAT false-positives are observed. Optionally add a slower `limit: 30,
  period: 3600` second bucket. (Signup can reuse the same pattern later — see
  §13.9.)

### 13.7 API contract (new endpoints + new 401 shape)

**`POST /api/v1/auth/signup`** — req `{ "username": "alice", "password": "hunter2secret" }`
→ `201` `{ "id": "664f…", "username": "alice" }`; `422`
`{ "errors": { "username": ["is already taken"], "password": ["is too short (minimum is 8 characters)"] } }`.

**`POST /api/v1/auth/login`** — req `{ "username": "alice", "password": "hunter2secret" }`
→ `200` `{ "id": "664f…", "username": "alice" }`; `401`
`{ "errors": { "base": ["Invalid username or password"] } }`; `429` throttled
(existing responder shape).

**`DELETE /api/v1/auth/logout`** — → `204 No Content`, clears cookie.

**`GET /api/v1/auth/me`** — → `200` `{ "id": "664f…", "username": "alice" }`;
`401` `{ "errors": { "base": ["Not authenticated"] } }`.

**New 401 on existing message endpoints:** `POST`/`GET /api/v1/messages` now
return `401 { "errors": { "base": ["Not authenticated"] } }` when no valid
identity cookie is present (previously they silently minted one). Frontend must
treat 401 as "redirect to login".

### 13.8 Checkpoint plan (continues CP1–CP12)

| CP | Story | Acceptance criteria | Role | Size |
|----|-------|---------------------|------|------|
| **CP13** | `User` model + bcrypt | `gem "bcrypt"` added & `bundle install` green; `User` (Mongoid, `has_secure_password`, normalized-lowercase username, format/length/uniqueness validations, unique index); model spec: digest set not plaintext, `authenticate` works, dup username rejected | Senior BE | S |
| **CP14** | `AuthController` signup/login/logout/me + routes | 4 routes; signup creates+signs in (201, no `password_digest`); login sets cookie / 401 generic on bad creds; logout 204 clears cookie; me 200/401; `skip_before_action` correct; CORS `:delete` added; request spec covers all + enumeration-safe 401 | Senior BE | M |
| **CP15** | `CurrentIdentity` rework → require auth | No more UUID minting; valid cookie → resolves real `User`; absent/invalid/stale → 401 `{errors:{base:["Not authenticated"]}}`; `sign_in`/`sign_out` reuse unchanged flag helpers; request spec proves `/api/v1/messages` 401s unauthenticated and scopes to `user.id` when authed; **owner_id path unchanged** | Senior BE | M |
| **CP16** | rack-attack login throttle | 6th login in 60s → 429 (existing JSON shape); disabled in test / via `RACK_ATTACK_DISABLED`; spec toggles guard | Junior BE | S |
| **CP17** | Frontend login/signup/logout UI + auth guard | Standalone `AuthComponent` (login+signup forms), `AuthService` (`withCredentials`) calling the 4 endpoints; `me` checked on app load to set auth state (HttpOnly cookie unreadable in JS); logged-out users see auth screen, logged-in see messenger; logout button; Karma specs via `HttpTestingController` | Senior FE | M |
| **CP18** | Frontend 401 wiring in API/store | `MessagesApiService`/store treat 401 as "not authenticated" → clear auth state + show login (not a generic error toast); HTTP interceptor or per-call handling; spec asserts 401 → login redirect | Senior FE | M |

Parallelization: CP13 first (blocks CP14/CP15). CP14+CP15 pair on backend; CP16
(junior) alongside. Frontend CP17→CP18 runs parallel once the §13.7 contract is
agreed. Integrate last.

### 13.9 Open questions for the director

1. **Orphaned pre-auth messages.** Messages created under old anonymous UUID
   `owner_id`s become inaccessible once identity requires a real `User` (no user
   has a UUID id). **Recommended accepted one-time consideration for a
   pre-launch app** — no migration; not a blocker. Confirm we don't need a
   backfill/claim flow.
2. **Signup rate limiting / open registration.** Registration is currently open
   and unthrottled. Add a signup throttle and/or invite-gating? (Cheap to add via
   the §13.6 pattern.)
3. **Username case policy** — confirm case-insensitive + lowercase-normalized is
   acceptable UX (display name is always lowercase).
4. **Session lifetime** — 1-year cookie (inherited). Want shorter expiry / idle
   timeout / server-side revocation? (Current signed cookie can't be revoked
   server-side short of rotating `secret_key_base`.)
5. **Password policy** — 8-char minimum only. Any complexity/breach-list
   requirements? (Recommend not over-engineering pre-launch.)

---

## 14. Bonus 2: Deployment (Render)

> Implements HLD §8 Bonus 2. **Superseded plan (2026-07-15): switched from
> Fly.io to Render.** Fly.io now requires a credit card on every new org and
> has no meaningful free tier (~$1.94/month minimum for an always-on
> machine); Render's free Web Service and Static Site instance types are
> genuinely $0/month with **no credit card required** to create them
> (confirmed via `render.com/docs/free`), at the cost of the free web
> service spinning down after 15 minutes idle (≈1 min cold start on the next
> request) and a 750-free-instance-hour/month cap. Acceptable trade-offs for
> a take-home demo. All of §0–§13 is unchanged.
>
> **Topology (locked upstream):** two Render services on different
> subdomains — `mysms-messenger-api` (Rails, Docker-runtime **Web Service**)
> and `mysms-messenger-web` (Angular, a free **Static Site** — no nginx/
> Docker needed for the frontend at all on Render) — so the SPA and API are
> **genuinely cross-origin**. Both are declared together in the repo-root
> `render.yaml` Blueprint (Render's IaC format), rather than per-service
> config files. Datastore is still **MongoDB Atlas free tier (M0)** — Render
> doesn't offer managed MongoDB, so Atlas is unchanged from the original
> plan. SMS stays the **fake gateway** (`SMS_PROVIDER=fake`) — no Twilio
> creds this pass. Render terminates TLS at its proxy, same as Fly did;
> `config.force_ssl = true` is already on (`production.rb:15`) and the
> `/health` SSL-redirect exclude (§14.6) still applies. Secrets
> (`SECRET_KEY_BASE`, `MONGO_URI`) are set in the Render dashboard
> (`sync: false` in `render.yaml`), never committed. Names/region below are
> **placeholders** the director finalizes at deploy time.

### 14.1 backend/`Dockerfile` (multi-stage)

Native extensions in the Gemfile that need a C toolchain at build time:
**bcrypt** (`~> 3.1`, compiles a C ext), **bson**/**mongo** (Mongoid 9's driver —
bson ships precompiled but falls back to compiling), **bootsnap**, **puma**. The
toolchain (`build-essential`) must exist in the **build** stage only; the final
stage stays lean (no compilers shipped).

```dockerfile
# ---- build stage: compile gems (needs a C toolchain) ----
FROM ruby:3.3-slim AS build
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle
# build-essential -> gcc/make for bcrypt + bson native ext; git for git_source
# gems; libyaml-dev for psych. No libpq/sqlite (Mongoid, not ActiveRecord).
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && bundle clean --force \
    && rm -rf "${BUNDLE_PATH}"/ruby/*/cache
COPY . .
RUN bundle exec bootsnap precompile app/ lib/ || true

# ---- final stage: lean runtime, no compilers ----
FROM ruby:3.3-slim AS final
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle
# Runtime libs only. No build-essential. tzdata for UTC timestamp formatting.
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash app
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
RUN chown -R app:app /app
USER app
EXPOSE 8080
# Bind 0.0.0.0 (NOT localhost) so Fly's proxy can reach the process; honor the
# PORT Fly injects, defaulting to 8080 to match fly.toml internal_port (§14.2).
CMD ["sh", "-c", "bin/rails server -b 0.0.0.0 -p ${PORT:-8080}"]
```

**Binding & port (Fly-critical):**
- Must bind `0.0.0.0` — a process bound to `localhost`/`127.0.0.1` is invisible
  to Fly's proxy and every health check + request fails.
- Fly injects `PORT` into the container (from `fly.toml`'s `internal_port`). The
  `CMD` honors `${PORT:-8080}`; we fix `internal_port = 8080` in fly.toml so the
  two always agree. (8080 chosen over Rails' default 3000 to match Fly's common
  convention — either works as long as Dockerfile bind == `internal_port`.)
- **Healthcheck-friendly boot:** `GET /health` returns `200 {"status":"ok"}` and
  **skips the auth `before_action`** (`health_controller.rb`,
  `skip_before_action :resolve_current_identity`, commit `6c5d42a`), so Fly's
  check gets 200 without a cookie. **But see the force_ssl caveat in §14.6 — the
  auth skip is necessary but NOT sufficient.**

**Note (2026-07-15, Render switch):** the doc above still reflects the
original `BUNDLE_DEPLOYMENT=1` + committed-`Gemfile.lock` design; the
Dockerfile actually committed to the repo does **not** use deployment mode
(no `Gemfile.lock` was ever generated — see the comment block at the top of
`backend/Dockerfile` and the README's "Known deploy-time caveat"). This is a
pre-existing, already-documented trade-off, unaffected by the Fly→Render
switch: Render's Docker runtime builds the same Dockerfile exactly as Fly
did, no changes needed there.

### 14.2 Render Blueprint (`render.yaml`, repo root)

Render's config-as-code format declares every service in one file at the
repo root (replaces the two separate `fly.toml` files, one per app, that
Fly's model required):

```yaml
services:
  - type: web
    name: mysms-messenger-api
    runtime: docker
    rootDir: backend
    dockerfilePath: ./Dockerfile
    plan: free
    region: oregon               # PLACEHOLDER — pick region near Atlas cluster
    healthCheckPath: /health
    autoDeploy: true
    envVars:
      - key: RAILS_ENV
        value: production
      - key: MESSAGE_REPOSITORY
        value: mongo
      - key: SMS_PROVIDER
        value: fake               # no Twilio creds this pass
      - key: CROSS_ORIGIN_COOKIES
        value: "true"             # genuinely cross-origin: SPA and API on different onrender.com subdomains
      - key: RAILS_LOG_TO_STDOUT
        value: "true"
      - key: CORS_ORIGINS
        value: https://mysms-messenger-web.onrender.com   # PLACEHOLDER — must equal the static site's real URL
      - key: SECRET_KEY_BASE
        sync: false               # set manually in the Render dashboard: `bin/rails secret`
      - key: MONGO_URI
        sync: false               # set manually: your Atlas mongodb+srv://... connection string

  - type: web
    name: mysms-messenger-web
    runtime: static
    rootDir: frontend
    buildCommand: npm ci && npm run build
    staticPublishPath: dist/frontend/browser
    plan: free
    autoDeploy: true
    routes:
      - type: rewrite
        source: /*
        destination: /index.html
```

**Secrets vs `envVars` (the split matters):**

| Value | Where | Why |
|---|---|---|
| `SECRET_KEY_BASE` | **Render dashboard, `sync: false` in render.yaml** | Signs the `:msms_owner` cookie; `production.rb` does `ENV.fetch("SECRET_KEY_BASE")` and **fails loudly at boot if missing**. Generate with `bin/rails secret`. |
| `MONGO_URI` | **Render dashboard, `sync: false`** | Atlas `mongodb+srv://` string embeds the DB password — never committed. `mongoid.yml` prod does `ENV.fetch("MONGO_URI")` (no default → hard fail if absent). |
| `CORS_ORIGINS` | **`envVars` in render.yaml** | The real web service URL (§14.6). Not secret per se, but must exactly match the static site's real `onrender.com` hostname once assigned. |
| `RAILS_ENV`, `MESSAGE_REPOSITORY`, `SMS_PROVIDER`, `CROSS_ORIGIN_COOKIES` | **`envVars` in render.yaml** | Non-secret config; fine to commit. |
| `TWILIO_*` | **omit** | Fake gateway this pass; add as dashboard secrets when creds arrive (Bonus, CP11 path). |
| `PORT` | **not set — Render injects it automatically** | The Dockerfile already honors `${PORT:-8080}` (unchanged from the Fly design); no config needed. |

Render assigns the real hostname once the service is first created (e.g.
`mysms-messenger-api.onrender.com`); there's no separate "set a secret"
command like `fly secrets set` — everything is done in the Render dashboard
or via the Blueprint's `envVars`.

### 14.3 Frontend: Render Static Site (no Docker/nginx needed)

Angular build uses the `@angular/build:application` builder (see
`angular.json`); its production output lands in **`dist/frontend/browser`**
(the `browser/` subfolder is mandatory with this builder — a common
wrong-path pitfall). The production config already does the
`environment.ts` → `environment.production.ts` `fileReplacement`
(angular.json), so `npm run build` (== `ng build`, default = production)
picks up the deployed `apiBaseUrl` — provided that file is correct at build
time (§14.5).

**Render switch simplifies this significantly**: a Render **Static Site**
builds the repo directly (`buildCommand: npm ci && npm run build`,
`staticPublishPath: dist/frontend/browser` in `render.yaml`) and serves the
output from Render's own CDN — no Dockerfile, no nginx config, and no
container to keep warm at all. Static Sites are free unconditionally (no
spin-down, no instance-hour cap), unlike the free Web Service tier. The
`frontend/Dockerfile` and `frontend/nginx.conf` used for the Fly.io deploy
have been removed as dead code; the SPA-fallback behavior they provided
(`try_files ... /index.html`) is replicated by the `routes: - type: rewrite`
entry in `render.yaml`.

### 14.5 Production `apiBaseUrl` — build-time substitution

Angular production builds are **static**: `apiBaseUrl` is baked in at `ng build`
time, so it **must be correct before the Render Static Site's `npm run build`
step runs** — there is no runtime env var to read (the compiled JS is already
minified with the value inlined). This constraint is identical to the Fly.io
design; only the hosting provider changed. `environment.production.ts` ships
`apiBaseUrl: 'https://mysms-messenger-api.onrender.com'` (placeholder) — it
must be the API service's absolute origin (never same-origin/`''`, since the
SPA and API are genuinely cross-origin services).

**Chosen approach (cleanest for a Blueprint-based deploy): commit the real API
URL into `environment.production.ts`.** Once the director knows the API
service's real name (Render assigns `https://<service-name>.onrender.com`),
set:
```ts
export const environment = {
  production: true,
  apiBaseUrl: 'https://mysms-messenger-api.onrender.com',   // API service origin, NO trailing /api
};
```
- Honors the existing convention (origin only; `MessagesApiService` appends
  `/api/v1/...`) — keeps the QA-M2 double-`/api` fix intact.
- **Rejected alternative:** inject the URL via a build-time environment
  variable substituted with `sed`/envsubst. More moving parts than a Static
  Site's build needs; a committed value is simpler and reviewable for a
  one-shot demo. (If the URL must stay out of git, this is a director call.)
- **Ordering dependency:** the API service must be named/created first so its
  hostname is known before the Static Site's build runs. Reflected in CP22.

### 14.6 CORS / cookies / force_ssl for the real deploy

- **CORS_ORIGINS** → the real static site origin, e.g.
  `https://mysms-messenger-web.onrender.com`, set as an `envVars` entry in
  `render.yaml` (or overridden in the Render dashboard) on the **API**
  service. `cors.rb` splits on comma and already sets `credentials: true`;
  wildcard is impossible with credentials (unchanged).
- **CROSS_ORIGIN_COOKIES=true** is **required** now (set in the API service's
  `envVars`, §14.2): the SPA and API are on different registrable hosts
  (different `onrender.com` subdomains), so the `:msms_owner` cookie must be
  `SameSite=None; Secure` to round-trip — exactly the switch `.env.example`
  documents. This depends on HTTPS, which Render provides.
- **Angular `withCredentials: true`** is already set in the API service (§8.3) —
  no change.

- **force_ssl vs the health check — THE FINDING (flagged, still applies on Render):**
  `config.silence_healthcheck_path = "/health"` (`production.rb:17`) is a Rails
  7.1 feature that **only silences the request LOG line** for that path. It does
  **NOT** exempt the path from `config.force_ssl`. These are two different
  mechanisms and are frequently conflated. With `force_ssl = true`, Rails
  **301-redirects any request it does not consider SSL** to `https://`. Render's
  external traffic arrives with `X-Forwarded-Proto: https` (Rails honors it, so
  real users are fine), **but Render's internal health checker may hit the
  container over plain HTTP and not carry `X-Forwarded-Proto: https`** — in
  which case `GET /health` returns **301, not 200, and the health check fails**,
  taking the whole deploy down even though the app is healthy. Same failure mode
  Fly had; the fix is provider-agnostic and needs no change for Render. The
  auth-skip on the health controller does not help here — the redirect happens
  in middleware before the controller runs.
  **Fix — exempt `/health` from the SSL redirect** in `production.rb` (already
  committed, unchanged by the Render switch):
  ```ruby
  config.force_ssl = true
  config.ssl_options = {
    redirect: { exclude: ->(request) { request.path == "/health" } }
  }
  ```
  This keeps HSTS + redirect for everything else while letting the internal
  health check succeed over HTTP.

### 14.7 MongoDB Atlas setup (runbook — director executes)

1. **Create a free cluster.** Atlas → *Build a Database* → **M0 Free** tier.
   Pick a cloud/region **close to the Render `region`** (e.g. AWS `us-west-2`
   ↔ Render `oregon`) to keep latency low. Name it e.g. `mysms`.
2. **Create a database user.** *Database Access* → *Add New Database User* →
   auth method **Password**. Username e.g. `mysms_app`, strong generated
   password. Role: **Read and write to any database** (or scope to
   `mysms_production`). Record the password (it goes into `MONGO_URI` only).
3. **Network access allow-list.** *Network Access* → *Add IP Address* →
   **`0.0.0.0/0`** (allow from anywhere). **Security tradeoff (flagged):**
   Render's free web service instances don't have stable egress IPs, so
   pinning specific IPs is impractical for this demo (same constraint Fly
   had); `0.0.0.0/0` is acceptable **only because** access still requires the
   DB username+password in the secret `MONGO_URI`. Note this as demo-only —
   a production hardening step is a dedicated egress IP / PrivateLink + a
   narrow allow-list.
4. **Get the connection string.** *Database* → *Connect* → *Drivers* → copy the
   `mongodb+srv://` string. Insert the user's password and append the DB name:
   ```
   mongodb+srv://mysms_app:<PASSWORD>@mysms.xxxxx.mongodb.net/mysms_production?retryWrites=true&w=majority
   ```
   (The `/mysms_production` path segment sets the default database Mongoid uses.)
5. **Set the secret** on the API service — Render dashboard → the
   `mysms-messenger-api` service → *Environment* → add `MONGO_URI` with the
   full connection string above (there's no CLI equivalent to `fly secrets
   set`; Render's `sync: false` env vars are entered directly in the
   dashboard, or via `render blueprint launch` prompts if using the CLI).
6. **Create indexes** after first boot (User unique index + Message compound
   index): open a shell to the running service from the Render dashboard
   (*Shell* tab on the service page) and run
   `bin/rails db:mongoid:create_indexes`.

### 14.8 Checkpoint plan (continues CP1–CP18)

| CP | Story | Acceptance criteria | Role | Size |
|----|-------|---------------------|------|------|
| **CP19** | Backend container + Render config | `backend/Dockerfile` (multi-stage, build-essential in build stage only, lean final); binds `0.0.0.0` on `${PORT:-8080}`; `render.yaml`'s `mysms-messenger-api` service (`runtime: docker`, `healthCheckPath: /health`, `envVars` for RAILS_ENV/MESSAGE_REPOSITORY/SMS_PROVIDER/CROSS_ORIGIN_COOKIES, `sync: false` secrets documented); `docker build` succeeds locally | Senior BE | M |
| **CP20** | Frontend Static Site config | `render.yaml`'s `mysms-messenger-web` service (`runtime: static`, `buildCommand: npm ci && npm run build`, `staticPublishPath: dist/frontend/browser`, SPA-fallback rewrite route); `npm run build` succeeds locally and produces `dist/frontend/browser/index.html` | Senior FE | S |
| **CP21** | Prod CORS/cookie/force_ssl fixes | `environment.production.ts` `apiBaseUrl` set to the API service's `onrender.com` origin (no `/api`); `production.rb`'s `config.ssl_options` `/health` redirect exclude (the force_ssl/health finding, §14.6, unchanged from the Fly design); confirm `CROSS_ORIGIN_COOKIES=true` + `CORS_ORIGINS` wiring; no code path other than config changes | Senior BE + FE | S |
| **CP22** | Atlas provisioning + live Render deploy | Atlas M0 cluster + DB user + `0.0.0.0/0` allow-list + `mongodb+srv://` string; set `SECRET_KEY_BASE`/`MONGO_URI` in the Render dashboard for the API service; deploy the Blueprint (API service creates first so its hostname is known for CP21's static site build — see §14.5 ordering); `create_indexes`; end-to-end signup→login→send→history over HTTPS across the two origins | Director + Tech Lead | M |

**BLOCKED-ON-DIRECTOR (flagged explicitly):** **CP22 cannot be completed by the
dev team** — it needs (a) a **Render account** (free, no credit card required
to create the Web Service/Static Site instances used here — confirmed via
`render.com/docs/free`), connected to the GitHub repo so it can read
`render.yaml`, and (b) the **Atlas cluster + `MONGO_URI`**. CP19–CP21 are
fully doable now (all artifacts committed, builds verified locally); CP22 is
the one checkpoint gated on the director supplying an account + credentials.
Also director must confirm the **final service names** (they feed
`CORS_ORIGINS` and the frontend `apiBaseUrl`) — a naming decision that must
precede CP21's frontend build.

### 14.9 Open questions for the director

1. **Final Render service names + region** — placeholders `mysms-messenger-api` /
   `mysms-messenger-web` and `oregon` used throughout; confirm so `CORS_ORIGINS`
   and the baked-in `apiBaseUrl` are correct (blocks CP21's frontend build).
2. **`apiBaseUrl` in git?** — recommended committed into
   `environment.production.ts` (§14.5); confirm OK, or a build-time
   substitution step can be added if the URL must stay out of the repo.
3. **Atlas allow-list `0.0.0.0/0`** — accepted for this demo (password-gated);
   confirm no requirement for a locked-down egress IP / PrivateLink this pass.
4. **Cold starts** — the free Web Service tier spins down after 15 minutes
   idle (§14 intro), so the first request after idle takes ~1 minute. This is
   very likely acceptable for a take-home demo — cheaper and simpler than
   Fly's paid always-on option — but flagging it explicitly as a trade-off.
5. **Render account / Atlas URI** — needed to execute CP22 (see BLOCKED note).

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

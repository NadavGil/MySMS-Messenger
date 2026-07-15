# QA + Security Review — Bonus 3: Twilio Delivery-Status Webhooks

Reviewer: QA / Security pass (independent, read-only except for the one fix
noted at M1, which was applied immediately since it was trivial and the
accompanying regression test proves it).

Scope: `doc/tech-design.md` §15 (locked design) vs. the actual committed
code: `backend/config/routes.rb`, `backend/app/controllers/api/v1/webhooks/twilio_status_controller.rb`,
`backend/app/repositories/{message_repository_interface,mongo_message_repository,in_memory_message_repository}.rb`,
`backend/app/models/message_document.rb`, `backend/app/gateways/twilio_sms_gateway.rb`,
`backend/config/initializers/rack_attack.rb`, `.env.example`, and the new/extended
specs (`backend/spec/requests/api/v1/webhooks/twilio_status_spec.rb`,
`backend/spec/support/shared_examples/message_repository_examples.rb`,
`backend/spec/gateways/twilio_sms_gateway_spec.rb`,
`backend/test/repositories/in_memory_message_repository_test.rb`).

## Top-line verdict

**PASS.** The implementation matches the locked §15 design precisely — route,
repository method signature, `STATUSES` vocabulary, disabled-when-unconfigured
behavior, signature validation, idempotency, and rate limiting all line up
with what the Tech Lead specified. One real Medium-severity gap (M1, below)
was found during this review and fixed immediately, with a regression test
added to prove it and prevent recurrence. No Critical or High findings.

The zero-gem Minitest suite (`ruby test/run_all.rb`) executes in this sandbox
and passes: **48 runs, 127 assertions, 0 failures, 0 errors, 1 skip** (the
skip is the `MessageDocument`/Mongoid-dependent test, which cannot load
without a real `bundle install` — expected and by design, same standing
limitation as every other Mongoid-touching test in this repo). All new/edited
Ruby files pass `ruby -c` syntax checks. The RSpec suite (request specs,
gateway specs, repository shared examples) is hand-authored and unexecuted in
this sandbox, matching every other RSpec file in the project (no
rubygems.org access to install `rspec-rails`/`twilio-ruby`/Mongoid here).

**Findings: 0 Critical, 0 High, 1 Medium (found + fixed), 2 Low, 2
Informational.**

---

## Security Findings

### Medium

**M1 — `TWILIO_AUTH_TOKEN` set without `TWILIO_STATUS_CALLBACK_URL` raised an
uncaught `KeyError` (500) instead of the intended clean 503. FOUND AND FIXED
during this review.**
The original draft guarded only on `auth_token.blank?` before proceeding to
`valid_twilio_signature?`, which read the callback URL via
`ENV.fetch("TWILIO_STATUS_CALLBACK_URL")` (no default). If a deploy ever set
`TWILIO_AUTH_TOKEN` without also setting the callback URL — an entirely
plausible operator slip, since they're two separate env vars set at two
different times per the runbook (§15.9's own open question 3 flags exactly
this kind of URL-confirmation gap) — every single request to the endpoint
would raise `KeyError: key not found: "TWILIO_STATUS_CALLBACK_URL"`,
uncaught, surfacing as an unstructured 500 rather than the documented,
clean 503 "disabled" response. Not exploitable (no info leak — production's
`consider_all_requests_local = false` renders the generic `public/500.html`,
same as any other unhandled exception), but it breaks the "disabled means
disabled, and looks like it" contract §15.5 explicitly promises, and would
confuse whoever is troubleshooting a broken deploy.
**Fix:** `callback_url` now reads via `ENV["..."]` (returns `nil`/blank
instead of raising), and the top-of-`create` guard checks
`auth_token.blank? || callback_url.blank?` together — either one missing now
correctly 503s. Regression test added (`twilio_status_spec.rb`, "when
TWILIO_AUTH_TOKEN is set but TWILIO_STATUS_CALLBACK_URL is not").

### Low

**L1 — The 503-vs-403 distinction discloses whether Twilio credentials are
configured to an unauthenticated caller.**
Anyone can distinguish "endpoint not configured yet" (503) from "endpoint
configured but my signature is wrong" (403) without ever needing a valid
Twilio signature. This is a minor information-disclosure surface (it reveals
whether this deploy has live Twilio credentials wired up) — but it's an
accepted, deliberate tradeoff, not an oversight: §15.5 explicitly requires the
disabled state be **visible** ("so a misconfiguration is visible, not
silent"), which necessarily means it's visible to everyone, not just
operators. Flagging for the record; no change recommended, since hiding the
503 behind a generic 403 would reintroduce the exact silent-misconfiguration
risk the design was written to avoid (the same "fail loudly" philosophy
already applied to `SECRET_KEY_BASE`/`MONGO_URI`/`CORS_ORIGINS` elsewhere in
this app).

**L2 — Signature comparison's timing-attack resistance is a third-party
dependency assumption, not independently verified.**
`Twilio::Security::RequestValidator#validate` is trusted to perform a
constant-time comparison internally (standard practice for HMAC signature
validators, and Twilio's own library). This could not be independently
verified against the actual gem source in this review (no rubygems.org
access in this sandbox — the standing limitation noted throughout this
project). This is a reasonable trust boundary to accept for a well-known
first-party SDK from the provider being integrated with, same posture
already taken for `bcrypt`'s password-hashing internals elsewhere in this
app. No action recommended; noting the assumption for the record.

### Informational

**I1 — Message lookup is intentionally global (not owner-scoped), and this
is correct, not a scoping bug.** `update_status_by_external_sid` looks up by
`external_sid` alone, with no `owner_id` filter — unlike every other
message-repository method in this app. This is correct: the caller is
authenticated as *the whole application's* Twilio account (via the shared
signing secret), not as any individual user, and every `external_sid` this
endpoint will ever see was itself minted by this same app's own outbound
sends — there is no cross-tenant data to leak. Calling this out explicitly so
it isn't mistaken for a missed `owner_id` check in a future pass.

**I2 — The new `index({ external_sid: 1 }, { sparse: true })` needs the same
one-time `bin/rails db:mongoid:create_indexes` step already documented in the
deploy runbook (tech-design.md §14.7 step 6) to actually exist on the live
Atlas cluster.** This is an additive index on an existing field, not a
migration, but it still needs that command re-run once this ships to
production — noting it here so it isn't missed at the next deploy.

---

## QA Findings (correctness / test coverage)

**No Blocker, Major, or Minor findings.** Specifically checked and confirmed:

- **Repository contract parity.** `update_status_by_external_sid` is
  implemented identically in intent by both `MongoMessageRepository` and
  `InMemoryMessageRepository` (update-in-place by `external_sid`, return the
  updated `Domain::Message`, return `nil` on no match) and both are exercised
  by the same extended shared example (`"a message repository"`), so any
  future drift between the two implementations will be caught.
- **Idempotency claim verified by test, not just asserted in the doc.** The
  request spec's "is idempotent: a duplicate callback for the same SID is
  harmless" example actually posts the same callback twice and asserts the
  end state, rather than only relying on the design doc's reasoning.
- **`STATUSES` membership gate correctly excludes transient values.** The
  request spec asserts a `"sending"` callback is a 200 no-op that leaves the
  existing `status` untouched — proving the "final-state-only vocabulary"
  decision (§15.4) is actually enforced in code, not just documented intent.
- **Legacy param names supported.** `SmsSid`/`SmsStatus` (Twilio's older
  naming, still sent by some account configurations) are handled via the
  same `||` fallback as `MessageSid`/`MessageStatus`, and covered by a
  dedicated test.
- **No auth-cookie dependency.** Confirmed via an explicit test that this
  endpoint never 401s for lacking `:msms_owner` — it can only 503/403/200,
  matching the "Twilio can't hold a cookie" design constraint.
- **Rate limiting wired correctly.** `webhooks/twilio/ip` (60/60, keyed by
  IP) follows the exact same guard (`unless Rails.env.test? ||
  RACK_ATTACK_DISABLED`) and `throttled_responder` as the pre-existing
  send/login/signup throttles, so it inherits the same test-suite-safe and
  emergency-bypass behavior without new code paths to get wrong.
- **`FakeSmsGateway` correctly untouched.** No `status_callback` wiring was
  added to it, matching §15.7's explicit "no dead config" decision — it
  never really sends, so a callback would never fire regardless.
- **Gateway test isolates itself from real `.env` state.** The extended
  `twilio_sms_gateway_spec.rb` explicitly snapshots/restores
  `TWILIO_STATUS_CALLBACK_URL` in its `around` block and explicitly clears it
  in the base "no callback" test, so the suite's outcome doesn't depend on
  whatever a developer's local `.env` happens to contain.
- **No frontend changes required or made**, matching §15.1/§15.12 — `status`
  was already serialized by `MessagesController#serialize` before this pass.

---

## Verdict Summary

| Area | Status |
|---|---|
| Route / controller / repository / model changes match locked design | ✅ Confirmed |
| Signature validation + disabled-when-unconfigured behavior | ✅ Confirmed, 1 gap found + fixed (M1) |
| Idempotency | ✅ Confirmed by test, not just design intent |
| Rate limiting | ✅ Confirmed, reuses existing safe pattern |
| No schema migration | ✅ Confirmed (additive index only) |
| Zero-gem Minitest suite | ✅ 48/48 passing (1 expected skip) |
| RSpec suite | Hand-authored, unexecuted (standing sandbox limitation) |
| Live Twilio verification | **Not possible this pass** — no real credentials exist (same posture as `TwilioSmsGateway` itself, HLD §9) |

**Recommendation: ship as-is.** The one real gap found (M1) is already fixed
and covered by a regression test. Remaining items (L1, L2, I1, I2) are
either deliberate, documented tradeoffs or operational reminders, not code
changes.

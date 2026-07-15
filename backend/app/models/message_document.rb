# Mongoid document. Referenced ONLY inside Repositories::MongoMessageRepository
# (tech-design.md §3.4) — never from controllers or services, so the
# datastore stays genuinely swappable behind the repository interface.
class MessageDocument
  include Mongoid::Document
  include Mongoid::Timestamps # created_at / updated_at (UTC)

  field :to_number,    type: String
  field :body,         type: String
  field :owner_id,     type: String
  field :status,       type: String, default: "queued"
  field :external_sid, type: String # Twilio SID (nullable)

  # Bug blitz (2026-07-15) follow-up: this document previously had zero
  # `validates` calls. Not currently exploitable — the only writer path
  # (Services::SendMessageService, called from MessagesController#create)
  # already validates to_number/body itself before ever calling
  # Repositories::MongoMessageRepository#create — but that left this model
  # with no defense-in-depth of its own, and no safety net if a future
  # writer ever bypassed the service layer. These deliberately DUPLICATE
  # (not share/reference) SendMessageService's E164_PATTERN/MAX_BODY_LENGTH
  # constants rather than depend on it directly — a Mongoid document
  # reaching up into Services would invert this app's layering (tech-design.md
  # §2.3: services depend on models, never the reverse). Kept in sync by
  # convention/comment, same as the independent Twilio-signature
  # implementation in backend/spec (see that file's header for the same
  # "duplicate deliberately, don't cross-depend" rationale).
  E164_PATTERN = /\A\+[1-9]\d{1,14}\z/
  MAX_BODY_LENGTH = 250

  validates :to_number, presence: true, format: { with: E164_PATTERN, message: "is not a valid E.164 number" }
  validates :body, presence: true, length: { maximum: MAX_BODY_LENGTH }
  validates :owner_id, presence: true
  validates :status, inclusion: { in: ->(_doc) { STATUSES } }

  index({ owner_id: 1, created_at: -1 })
  # Bonus 3 (tech-design.md §15.3): lookup index for the Twilio status
  # webhook. sparse because a send-failure record has external_sid: nil and
  # should not occupy the index.
  index({ external_sid: 1 }, { sparse: true })

  # Full delivery-status vocabulary (Bonus 3, tech-design.md §15.4). Plain
  # String, NOT a hard Mongoid enum, so values need no migration. sent/failed
  # are set synchronously at send time (SendMessageService); delivered/
  # undelivered/failed arrive via the Twilio status webhook
  # (Api::V1::Webhooks::TwilioStatusController). Twilio's transient
  # "sending" callback value (NOT a member of this list) is intentionally
  # not persisted, via the controller's STATUSES membership gate — but
  # "queued" IS a member of this list (bug blitz 2026-07-15 correction: an
  # earlier version of this comment, and of tech-design.md §15.4, wrongly
  # claimed "queued" was filtered out the same way "sending" is; it isn't,
  # since it's a real value here). What actually stops a delayed/out-of-order
  # "queued" or "sent" callback from regressing an already-`delivered`
  # message backward is the repository-level monotonicity guard
  # (Repositories::MessageRepositoryInterface::STATUS_RANK /
  # .regressive_status?), not this membership check.
  STATUSES = %w[queued sent failed delivered undelivered].freeze
end

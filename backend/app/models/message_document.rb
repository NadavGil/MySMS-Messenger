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
  # sending/queued callback values are intentionally NOT persisted as status
  # transitions (see the controller's STATUSES membership gate).
  STATUSES = %w[queued sent failed delivered undelivered].freeze
end

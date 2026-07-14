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

  # delivered/undelivered are future webhook values (Bonus 3) — status stays
  # a plain String enum, not a hard Mongoid enum, so new values need no
  # migration.
  STATUSES = %w[queued sent failed].freeze
end

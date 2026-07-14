module Repositories
  # Concrete MongoDB-backed implementation (tech-design.md §3.2). Wraps
  # MessageDocument (Mongoid) and only ever hands Domain::Message objects
  # back across the DAL boundary.
  class MongoMessageRepository
    include MessageRepositoryInterface

    def create(attrs)
      document = MessageDocument.create!(
        to_number: attrs.fetch(:to_number),
        body: attrs.fetch(:body),
        owner_id: attrs.fetch(:owner_id),
        status: attrs.fetch(:status, "queued"),
        external_sid: attrs[:external_sid]
      )
      to_domain(document)
    end

    def find_for_owner(owner_id)
      MessageDocument
        .where(owner_id: owner_id)
        .order(created_at: :desc)
        .map { |document| to_domain(document) }
    end

    private

    def to_domain(document)
      Domain::Message.new(
        id: document.id.to_s,
        to_number: document.to_number,
        body: document.body,
        owner_id: document.owner_id,
        status: document.status,
        external_sid: document.external_sid,
        created_at: document.created_at
      )
    end
  end
end

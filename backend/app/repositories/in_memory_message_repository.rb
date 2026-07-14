require "securerandom"

module Repositories
  # Test/dev fake (tech-design.md §3.3). Backed by an in-process Array —
  # no Mongo, no network. Used by RSpec specs and by any run with
  # MESSAGE_REPOSITORY=in_memory (fast demos). Not shared across processes;
  # each instance owns its own store, which is exactly what specs want.
  class InMemoryMessageRepository
    include MessageRepositoryInterface

    def initialize
      @records = []
    end

    def create(attrs)
      message = Domain::Message.new(
        id: SecureRandom.uuid,
        to_number: attrs.fetch(:to_number),
        body: attrs.fetch(:body),
        owner_id: attrs.fetch(:owner_id),
        status: attrs.fetch(:status, "queued"),
        external_sid: attrs[:external_sid],
        created_at: Time.now.utc
      )
      @records << message
      message
    end

    def find_for_owner(owner_id)
      @records.select { |message| message.owner_id == owner_id }
              .sort_by(&:created_at)
              .reverse
    end

    # Test helper only — not part of the documented interface.
    def clear!
      @records.clear
    end
  end
end

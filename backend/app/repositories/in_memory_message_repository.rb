require "securerandom"

module Repositories
  # Test/dev fake (tech-design.md §3.3). Backed by an in-process Array —
  # no Mongo, no network. Used by RSpec specs and by any run with
  # MESSAGE_REPOSITORY=in_memory (fast demos).
  #
  # THREAD-SAFETY (qa-report-round1.md N2): now that Services::Container
  # memoizes a single shared instance per process (fix for Blocker B1), this
  # instance can be mutated concurrently by multiple Puma threads. `@records`
  # is guarded by a Mutex around every read/write so `create` and
  # `find_for_owner` can't race (e.g. a concurrent push corrupting the array,
  # or a read observing a half-written state).
  class InMemoryMessageRepository
    include MessageRepositoryInterface

    def initialize
      @records = []
      @mutex = Mutex.new
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
      @mutex.synchronize { @records << message }
      message
    end

    def find_for_owner(owner_id)
      @mutex.synchronize do
        @records.select { |message| message.owner_id == owner_id }
                .sort_by(&:created_at)
                .reverse
      end
    end

    # Bonus 3 (tech-design.md §15.3). Unknown external_sid -> nil (safe
    # no-op, matches MongoMessageRepository's behavior).
    def update_status_by_external_sid(external_sid, status)
      @mutex.synchronize do
        index = @records.index { |m| m.external_sid == external_sid }
        return nil if index.nil?

        updated = @records[index].dup
        updated.status = status
        @records[index] = updated
        updated
      end
    end

    # Test helper only — not part of the documented interface.
    def clear!
      @mutex.synchronize { @records.clear }
    end
  end
end

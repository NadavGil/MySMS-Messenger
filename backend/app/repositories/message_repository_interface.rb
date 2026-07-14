module Repositories
  # Documented contract for message persistence (tech-design.md §3.1).
  # Ruby is duck-typed, so this module exists to declare intent: both
  # MongoMessageRepository and InMemoryMessageRepository `include` it. Methods
  # raise NotImplementedError so an implementation that forgets to override
  # a method fails loudly instead of silently no-op-ing.
  module MessageRepositoryInterface
    # @param attrs [Hash] to_number:, body:, owner_id:, status:, external_sid:
    # @return [Domain::Message] the persisted message (with id + created_at)
    def create(attrs)
      raise NotImplementedError, "#{self.class} must implement #create"
    end

    # @param owner_id [String]
    # @return [Array<Domain::Message>] newest-first
    def find_for_owner(owner_id)
      raise NotImplementedError, "#{self.class} must implement #find_for_owner"
    end
  end
end

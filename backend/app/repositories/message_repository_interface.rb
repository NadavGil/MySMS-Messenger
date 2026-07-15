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

    # Bonus 3 (tech-design.md §15.3): update delivery status by the
    # provider-assigned message id (Twilio SID). A deliberate, non-error
    # "safe no-op" for an unknown external_sid — callers (the webhook
    # controller) rely on `nil` to answer Twilio 200 without writing anything,
    # since a non-2xx would make Twilio retry forever for a SID that will
    # never exist.
    #
    # @param external_sid [String]
    # @param status [String] caller is responsible for passing only a member
    #   of MessageDocument::STATUSES; this method does not re-whitelist.
    # @return [Domain::Message, nil] the updated message, or nil on no match
    def update_status_by_external_sid(external_sid, status)
      raise NotImplementedError, "#{self.class} must implement #update_status_by_external_sid"
    end
  end
end

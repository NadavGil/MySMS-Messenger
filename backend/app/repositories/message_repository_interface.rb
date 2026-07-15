module Repositories
  # Documented contract for message persistence (tech-design.md §3.1).
  # Ruby is duck-typed, so this module exists to declare intent: both
  # MongoMessageRepository and InMemoryMessageRepository `include` it. Methods
  # raise NotImplementedError so an implementation that forgets to override
  # a method fails loudly instead of silently no-op-ing.
  module MessageRepositoryInterface
    # Bug blitz (2026-07-15) follow-up: find_for_owner used to return a
    # long-lived account's ENTIRE history unbounded — an ever-growing
    # response payload and DB scan with no ceiling. Full cursor/page-based
    # pagination would need a frontend UX change (load more / infinite
    # scroll) that's out of proportion to what was a Low-severity finding;
    # instead, both implementations cap at this many of the most recent
    # messages per owner, shared here so the two implementations can't drift
    # out of sync with each other.
    MAX_RESULTS_PER_OWNER = 500

    # Bug blitz (2026-07-15) follow-up: Twilio's callback delivery is
    # at-least-once with no ordering guarantee, so a delayed/retried
    # callback could otherwise regress a message's status backward (e.g. a
    # "sent" callback arriving after an already-processed "delivered" one).
    # Rank used by #update_status_by_external_sid implementations to reject
    # any update that doesn't strictly move a message forward. "queued" and
    # "sent" mirror Twilio's own pre-terminal progression; "delivered",
    # "failed", and "undelivered" are all equally terminal (same rank) —
    # once any one of them lands, nothing else should overwrite it.
    STATUS_RANK = {
      "queued" => 0,
      "sent" => 1,
      "delivered" => 2,
      "failed" => 2,
      "undelivered" => 2,
    }.freeze

    # Returns true if writing `new_status` over `current_status` would hold
    # steady or move backward per STATUS_RANK (i.e. should be rejected as a
    # stale/duplicate no-op). An unrecognized status on either side ranks
    # below every known status, so it's always treated as non-advancing
    # (never overwrites a known status, and is itself always overwritable).
    def self.regressive_status?(current_status, new_status)
      STATUS_RANK.fetch(new_status, -1) <= STATUS_RANK.fetch(current_status, -1)
    end

    # @param attrs [Hash] to_number:, body:, owner_id:, status:, external_sid:
    # @return [Domain::Message] the persisted message (with id + created_at)
    def create(attrs)
      raise NotImplementedError, "#{self.class} must implement #create"
    end

    # @param owner_id [String]
    # @return [Array<Domain::Message>] newest-first, capped at
    #   MAX_RESULTS_PER_OWNER most recent messages
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
    # Bug blitz (2026-07-15) follow-up: also a safe no-op — returning the
    # message UNCHANGED, not nil, since a matching record does exist — when
    # `regressive_status?` says the new status wouldn't move the message
    # forward. Guards against a delayed/out-of-order Twilio callback
    # clobbering a more-advanced status that already landed.
    #
    # @param external_sid [String]
    # @param status [String] caller is responsible for passing only a member
    #   of MessageDocument::STATUSES; this method does not re-whitelist.
    # @return [Domain::Message, nil] the (possibly unchanged) message, or nil
    #   on no match
    def update_status_by_external_sid(external_sid, status)
      raise NotImplementedError, "#{self.class} must implement #update_status_by_external_sid"
    end
  end
end

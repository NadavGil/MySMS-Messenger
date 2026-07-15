module Repositories
  # Repositories::RepositoryError now lives in its own file
  # (app/repositories/repository_error.rb) — see that file for why.

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
    rescue Mongo::Error => e
      raise_repository_error("create", e)
    rescue Mongoid::Errors::Validation => e
      # Bug blitz (2026-07-15) follow-up: MessageDocument previously had NO
      # `validates` calls, so this could never actually fire — added purely
      # as a safety net now that it does have some (see that model's
      # comments). Should be UNREACHABLE in normal operation:
      # Services::SendMessageService already validates to_number/body before
      # ever calling this method. If it ever does fire, that means something
      # bypassed the service layer, which is itself worth knowing about —
      # hence the distinct log line — but the caller still just sees the
      # same structured 5xx as any other repository failure, not a raw
      # Mongoid backtrace.
      raise_validation_error("create", e)
    end

    def find_for_owner(owner_id)
      MessageDocument
        .where(owner_id: owner_id)
        .order(created_at: :desc)
        .limit(MessageRepositoryInterface::MAX_RESULTS_PER_OWNER)
        .map { |document| to_domain(document) }
    rescue Mongo::Error => e
      raise_repository_error("find_for_owner", e)
    end

    # Bonus 3 (tech-design.md §15.3). Unknown external_sid -> nil (safe
    # no-op, not an error) so the webhook controller can answer Twilio 200
    # without writing anything.
    def update_status_by_external_sid(external_sid, status)
      document = MessageDocument.where(external_sid: external_sid).first
      return nil if document.nil?

      if MessageRepositoryInterface.regressive_status?(document.status, status)
        return to_domain(document)
      end

      document.update!(status: status)
      to_domain(document)
    rescue Mongo::Error => e
      raise_repository_error("update_status_by_external_sid", e)
    rescue Mongoid::Errors::Validation => e
      # Should be unreachable: the webhook controller only ever passes a
      # status that's already a member of MessageDocument::STATUSES (same
      # rationale as #create's rescue above).
      raise_validation_error("update_status_by_external_sid", e)
    end

    private

    def raise_repository_error(operation, error)
      # Log the real driver exception for operators, but never leak it raw
      # past this boundary — controllers/services should only ever see a
      # RepositoryError (qa-report-round1.md N3: a Mongo outage should
      # surface as a structured 5xx, not a leaked driver stack trace).
      Rails.logger.error(
        "[MongoMessageRepository##{operation}] Mongo driver error: #{error.class}: #{error.message}"
      )
      raise RepositoryError, "Message storage is temporarily unavailable (#{operation} failed)"
    end

    def raise_validation_error(operation, error)
      # Bug blitz (2026-07-15) follow-up — see the two rescue sites above.
      # Logged distinctly from a driver/outage error since this means an
      # in-process document failed its OWN model validations, not that Mongo
      # itself is unreachable — a meaningfully different failure mode for
      # whoever's reading logs, even though it maps to the same RepositoryError
      # for the caller.
      Rails.logger.error(
        "[MongoMessageRepository##{operation}] Unexpected MessageDocument validation failure " \
        "(should have been caught by the caller before reaching the repository): #{error.message}"
      )
      raise RepositoryError, "Message storage is temporarily unavailable (#{operation} failed)"
    end

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

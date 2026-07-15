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
    end

    def find_for_owner(owner_id)
      MessageDocument
        .where(owner_id: owner_id)
        .order(created_at: :desc)
        .map { |document| to_domain(document) }
    rescue Mongo::Error => e
      raise_repository_error("find_for_owner", e)
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

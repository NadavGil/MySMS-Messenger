module Repositories
  # Raised by MongoMessageRepository when the underlying Mongo driver fails
  # (connection refused, replica-set failover, timeout, etc). Callers
  # (services/controllers) can rescue this one repository-layer error
  # instead of needing to know about Mongo::Error/Mongo::Error::* internals
  # (qa-report-round1.md N3).
  #
  # REFACTOR (post-live-run audit): split out of mongo_message_repository.rb.
  # Zeitwerk's one-file-one-constant convention only registers an autoload
  # entry for the constant matching a file's name — mongo_message_repository.rb
  # only autoloads Repositories::MongoMessageRepository. RepositoryError was
  # previously only defined as a *side effect* of that file happening to load
  # first, which always worked in practice (you can't raise this error
  # without MongoMessageRepository already being loaded to raise it) but was
  # fragile and one autoload-ordering assumption away from the exact class of
  # bug this codebase just spent an afternoon debugging live. Its own file
  # gives it its own real autoload entry, independent of load order.
  class RepositoryError < StandardError; end
end

module Services
  # Use-case: list messages scoped to a single owner (tech-design.md §5).
  # Thin wrapper around the repository so the controller never touches the
  # DAL directly; kept as its own class (rather than folded into
  # SendMessageService) to mirror the §2.3 folder-per-use-case layout.
  class ListMessagesService
    def initialize(repository:)
      @repository = repository
    end

    # @param owner_id [String]
    # @return [Array<Domain::Message>] newest-first, scoped to owner_id
    def call(owner_id:)
      @repository.find_for_owner(owner_id)
    end
  end
end

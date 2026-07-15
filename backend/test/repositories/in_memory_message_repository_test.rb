require_relative "../test_helper"

class InMemoryMessageRepositoryTest < Minitest::Test
  def setup
    @repo = Repositories::InMemoryMessageRepository.new
  end

  def test_create_returns_a_persisted_domain_message_with_id_and_created_at
    message = @repo.create(
      to_number: "+15551234567",
      body: "hi",
      owner_id: "owner-1",
      status: "sent",
      external_sid: "SMabc"
    )

    assert_instance_of Domain::Message, message
    refute_nil message.id
    refute_nil message.created_at
    assert_equal "+15551234567", message.to_number
    assert_equal "owner-1", message.owner_id
    assert_equal "sent", message.status
    assert_equal "SMabc", message.external_sid
  end

  def test_create_defaults_status_to_queued_and_external_sid_to_nil
    message = @repo.create(to_number: "+15551234567", body: "hi", owner_id: "owner-1")

    assert_equal "queued", message.status
    assert_nil message.external_sid
  end

  def test_create_raises_when_required_attrs_missing
    assert_raises(KeyError) { @repo.create(body: "hi", owner_id: "owner-1") }
  end

  def test_find_for_owner_scopes_to_owner_and_excludes_others
    mine = @repo.create(to_number: "+15551111111", body: "a", owner_id: "owner-1")
    @repo.create(to_number: "+15552222222", body: "b", owner_id: "owner-2")

    results = @repo.find_for_owner("owner-1")

    assert_equal [mine.id], results.map(&:id)
  end

  def test_find_for_owner_returns_newest_first
    first = @repo.create(to_number: "+15551111111", body: "first", owner_id: "owner-1")
    first.created_at = Time.now.utc - 10
    second = @repo.create(to_number: "+15552222222", body: "second", owner_id: "owner-1")
    second.created_at = Time.now.utc - 5
    third = @repo.create(to_number: "+15553333333", body: "third", owner_id: "owner-1")
    third.created_at = Time.now.utc

    results = @repo.find_for_owner("owner-1")

    assert_equal [third.id, second.id, first.id], results.map(&:id)
  end

  def test_find_for_owner_returns_empty_array_for_unknown_owner
    assert_equal [], @repo.find_for_owner("nobody")
  end

  # This is exactly the regression QA flagged earlier: a single Container-
  # memoized repository instance must accumulate state across multiple
  # calls, not reset between them.
  def test_state_persists_across_multiple_calls_on_the_same_instance
    @repo.create(to_number: "+15551111111", body: "one", owner_id: "owner-1")
    assert_equal 1, @repo.find_for_owner("owner-1").size

    @repo.create(to_number: "+15552222222", body: "two", owner_id: "owner-1")
    assert_equal 2, @repo.find_for_owner("owner-1").size

    @repo.create(to_number: "+15553333333", body: "three", owner_id: "owner-1")
    assert_equal 3, @repo.find_for_owner("owner-1").size
  end

  # Exercises the Mutex fix (qa-report-round1.md N2): many threads writing
  # concurrently to the SAME repository instance must not lose writes or
  # corrupt the underlying array.
  def test_concurrent_writes_from_many_threads_do_not_lose_data
    thread_count = 20
    threads = Array.new(thread_count) do |i|
      Thread.new do
        @repo.create(
          to_number: "+1555000#{format('%04d', i)}",
          body: "concurrent-#{i}",
          owner_id: "shared-owner"
        )
      end
    end
    threads.each(&:join)

    results = @repo.find_for_owner("shared-owner")

    assert_equal thread_count, results.size
    assert_equal thread_count, results.map(&:id).uniq.size
    assert_equal (0...thread_count).map { |i| "concurrent-#{i}" }.sort,
                 results.map(&:body).sort
  end

  # Bug blitz (2026-07-15) follow-up: find_for_owner used to be unbounded.
  # Create one more than the cap and confirm only the cap's worth of the
  # NEWEST messages come back (not an arbitrary/oldest slice).
  def test_find_for_owner_caps_results_at_max_and_keeps_the_newest
    cap = Repositories::MessageRepositoryInterface::MAX_RESULTS_PER_OWNER
    base_time = Time.now.utc - (cap + 1)
    created = (0..cap).map do |i|
      message = @repo.create(to_number: "+15550000000", body: "msg-#{i}", owner_id: "owner-1")
      message.created_at = base_time + i
      message
    end

    results = @repo.find_for_owner("owner-1")

    assert_equal cap, results.size
    # created[cap] is the newest (highest i / created_at); created[0] is the
    # oldest and must have been dropped by the cap.
    assert_equal created[cap].id, results.first.id
    refute_includes results.map(&:id), created[0].id
  end

  def test_clear_empties_the_repository
    @repo.create(to_number: "+15551111111", body: "a", owner_id: "owner-1")
    @repo.clear!

    assert_equal [], @repo.find_for_owner("owner-1")
  end

  # Bonus 3 (tech-design.md §15.3, §15.10 "hit" case).
  def test_update_status_by_external_sid_updates_the_matching_message
    created = @repo.create(
      to_number: "+15551234567", body: "hi", owner_id: "owner-1",
      status: "sent", external_sid: "SIDX"
    )

    updated = @repo.update_status_by_external_sid("SIDX", "delivered")

    assert_instance_of Domain::Message, updated
    assert_equal created.id, updated.id
    assert_equal "delivered", updated.status
    # and it's the persisted record, not just the returned value:
    assert_equal "delivered", @repo.find_for_owner("owner-1").first.status
  end

  # Bonus 3 (tech-design.md §15.3, §15.10 "miss" case).
  def test_update_status_by_external_sid_returns_nil_on_unknown_sid
    assert_nil @repo.update_status_by_external_sid("NO_SUCH_SID", "delivered")
  end

  # Bug blitz (2026-07-15) follow-up: a delayed/retried Twilio callback must
  # not regress an already-more-advanced status backward.
  def test_update_status_by_external_sid_rejects_a_regressive_update
    @repo.create(
      to_number: "+15551234567", body: "hi", owner_id: "owner-1",
      status: "sent", external_sid: "SIDY"
    )
    @repo.update_status_by_external_sid("SIDY", "delivered")

    result = @repo.update_status_by_external_sid("SIDY", "sent")

    assert_equal "delivered", result.status
    assert_equal "delivered", @repo.find_for_owner("owner-1").first.status
  end

  # A duplicate/repeat callback at the SAME rank is also rejected (no
  # flip-flopping between two equally-terminal statuses).
  def test_update_status_by_external_sid_rejects_a_same_rank_update
    @repo.create(
      to_number: "+15551234567", body: "hi", owner_id: "owner-1",
      status: "sent", external_sid: "SIDZ"
    )
    @repo.update_status_by_external_sid("SIDZ", "delivered")

    result = @repo.update_status_by_external_sid("SIDZ", "undelivered")

    assert_equal "delivered", result.status
  end

  # A genuinely forward update still applies normally.
  def test_update_status_by_external_sid_still_allows_a_forward_update
    @repo.create(
      to_number: "+15551234567", body: "hi", owner_id: "owner-1",
      status: "queued", external_sid: "SIDW"
    )

    result = @repo.update_status_by_external_sid("SIDW", "sent")

    assert_equal "sent", result.status
  end

  # Bonus 3 (tech-design.md §15.4 STATUSES membership gate — this test lives
  # at the repository/domain layer since MessageDocument itself, and the
  # controller that reads it, both require a full Rails boot).
  def test_statuses_constant_has_the_locked_final_vocabulary
    # Guard: MessageDocument requires Mongoid, which requires a full Rails
    # boot with the mongoid gem installed — unavailable in this sandbox
    # (standing rubygems.org limitation). Skip gracefully if it can't load
    # (LoadError, NOT a StandardError, so it must be rescued explicitly),
    # rather than failing the whole Minitest run over an unrelated
    # dependency; this assertion DOES run wherever a real bundle install
    # has succeeded (i.e. wherever this whole app actually runs).
    begin
      require_relative "../../app/models/message_document"
    rescue LoadError, NameError
      skip "MessageDocument/Mongoid not loadable in this sandbox"
    end

    assert_equal %w[queued sent failed delivered undelivered], MessageDocument::STATUSES
  end
end

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

  def test_clear_empties_the_repository
    @repo.create(to_number: "+15551111111", body: "a", owner_id: "owner-1")
    @repo.clear!

    assert_equal [], @repo.find_for_owner("owner-1")
  end
end

require_relative "../test_helper"

class ListMessagesServiceTest < Minitest::Test
  def setup
    @repository = Repositories::InMemoryMessageRepository.new
    @service = Services::ListMessagesService.new(repository: @repository)
  end

  def test_returns_empty_array_when_owner_has_no_messages
    assert_equal [], @service.call(owner_id: "owner-1")
  end

  def test_scopes_results_to_the_given_owner
    mine = @repository.create(to_number: "+15551111111", body: "mine", owner_id: "owner-1")
    @repository.create(to_number: "+15552222222", body: "not-mine", owner_id: "owner-2")

    results = @service.call(owner_id: "owner-1")

    assert_equal [mine.id], results.map(&:id)
  end

  def test_returns_newest_first
    older = @repository.create(to_number: "+15551111111", body: "older", owner_id: "owner-1")
    older.created_at = Time.now.utc - 100
    newer = @repository.create(to_number: "+15552222222", body: "newer", owner_id: "owner-1")
    newer.created_at = Time.now.utc

    results = @service.call(owner_id: "owner-1")

    assert_equal [newer.id, older.id], results.map(&:id)
  end

  def test_count_matches_number_of_messages_created_for_owner
    3.times { |i| @repository.create(to_number: "+1555111111#{i}", body: "m#{i}", owner_id: "owner-1") }
    @repository.create(to_number: "+15552222222", body: "other", owner_id: "owner-2")

    assert_equal 3, @service.call(owner_id: "owner-1").count
  end
end

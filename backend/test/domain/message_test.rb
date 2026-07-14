require_relative "../test_helper"

class MessageTest < Minitest::Test
  def test_keyword_init_sets_all_fields
    created_at = Time.now.utc
    message = Domain::Message.new(
      id: "abc-123",
      to_number: "+15551234567",
      body: "hello",
      owner_id: "owner-1",
      status: "sent",
      external_sid: "SMdeadbeef",
      created_at: created_at
    )

    assert_equal "abc-123", message.id
    assert_equal "+15551234567", message.to_number
    assert_equal "hello", message.body
    assert_equal "owner-1", message.owner_id
    assert_equal "sent", message.status
    assert_equal "SMdeadbeef", message.external_sid
    assert_equal created_at, message.created_at
  end

  def test_keyword_init_allows_partial_construction_with_nil_defaults
    message = Domain::Message.new(id: "x")

    assert_equal "x", message.id
    assert_nil message.to_number
    assert_nil message.body
    assert_nil message.owner_id
    assert_nil message.status
    assert_nil message.external_sid
    assert_nil message.created_at
  end

  def test_rejects_positional_construction
    # keyword_init: true means the positional form must not silently work.
    assert_raises(ArgumentError) { Domain::Message.new("abc-123") }
  end

  def test_members_match_documented_fields
    assert_equal(
      [:id, :to_number, :body, :owner_id, :status, :external_sid, :created_at],
      Domain::Message.members
    )
  end

  def test_equality_is_value_based
    attrs = { id: "1", to_number: "+15551234567", body: "hi", owner_id: "o",
              status: "sent", external_sid: "SM1", created_at: Time.at(0) }
    a = Domain::Message.new(**attrs)
    b = Domain::Message.new(**attrs)

    assert_equal a, b
  end
end

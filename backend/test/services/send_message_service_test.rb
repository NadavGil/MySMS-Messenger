require_relative "../test_helper"

# Hand-rolled fakes (constructor-injected collaborators) -- no mocking gem
# available in this sandbox.
class FakeRepositoryDouble
  attr_reader :created_with

  def initialize
    @created_with = []
  end

  def create(attrs)
    @created_with << attrs
    Domain::Message.new(**attrs.merge(id: "fake-id-#{@created_with.size}", created_at: Time.now.utc))
  end
end

class ScriptedGatewayDouble
  def initialize(result:)
    @result = result
    @calls = []
  end

  attr_reader :calls

  def send_sms(to:, body:)
    @calls << { to: to, body: body }
    @result
  end
end

class SendMessageServiceTest < Minitest::Test
  VALID_TO = "+15551234567"

  def build_service(gateway_result:)
    repository = FakeRepositoryDouble.new
    gateway = ScriptedGatewayDouble.new(result: gateway_result)
    service = Services::SendMessageService.new(repository: repository, gateway: gateway)
    [service, repository, gateway]
  end

  def success_result
    Gateways::SmsGatewayInterface::Result.new(success: true, external_sid: "SMok123", error: nil)
  end

  def failure_result
    Gateways::SmsGatewayInterface::Result.new(success: false, external_sid: nil, error: "boom")
  end

  def test_valid_send_persists_with_status_sent_and_gateway_sid
    service, repository, gateway = build_service(gateway_result: success_result)

    result = service.call(to_number: VALID_TO, body: "hello", owner_id: "owner-1")

    assert result.ok?
    assert_nil result.errors
    assert_equal "sent", result.message.status
    assert_equal "SMok123", result.message.external_sid
    assert_equal 1, gateway.calls.size
    assert_equal 1, repository.created_with.size
  end

  def test_gateway_failure_still_persists_as_failed_with_nil_external_sid
    service, repository, gateway = build_service(gateway_result: failure_result)

    result = service.call(to_number: VALID_TO, body: "hello", owner_id: "owner-1")

    assert result.ok?
    assert_equal "failed", result.message.status
    assert_nil result.message.external_sid
    assert_equal 1, gateway.calls.size
    assert_equal 1, repository.created_with.size
  end

  def test_missing_to_number_is_rejected_without_touching_collaborators
    service, repository, gateway = build_service(gateway_result: success_result)

    result = service.call(to_number: nil, body: "hello", owner_id: "owner-1")

    refute result.ok?
    assert_equal ["is required"], result.errors[:to_number]
    assert_equal 0, gateway.calls.size
    assert_equal 0, repository.created_with.size
  end

  def test_malformed_to_number_is_rejected
    service, = build_service(gateway_result: success_result)

    result = service.call(to_number: "not-a-number", body: "hello", owner_id: "owner-1")

    refute result.ok?
    assert_equal ["is not a valid E.164 number"], result.errors[:to_number]
  end

  def test_non_e164_to_number_missing_plus_is_rejected
    service, = build_service(gateway_result: success_result)

    result = service.call(to_number: "15551234567", body: "hello", owner_id: "owner-1")

    refute result.ok?
    assert_equal ["is not a valid E.164 number"], result.errors[:to_number]
  end

  def test_non_string_to_number_is_rejected_without_raising
    service, repository, gateway = build_service(gateway_result: success_result)

    result = service.call(to_number: { "a" => "1" }, body: "hello", owner_id: "owner-1")

    refute result.ok?
    assert_equal ["must be a string"], result.errors[:to_number]
    assert_equal 0, gateway.calls.size
    assert_equal 0, repository.created_with.size
  end

  def test_blank_body_is_rejected
    service, = build_service(gateway_result: success_result)

    result = service.call(to_number: VALID_TO, body: "", owner_id: "owner-1")

    refute result.ok?
    assert_equal ["is required"], result.errors[:body]
  end

  def test_body_over_max_length_is_rejected
    service, = build_service(gateway_result: success_result)

    result = service.call(to_number: VALID_TO, body: "x" * 251, owner_id: "owner-1")

    refute result.ok?
    assert_equal ["must be 250 characters or fewer"], result.errors[:body]
  end

  def test_body_at_max_length_is_accepted
    service, = build_service(gateway_result: success_result)

    result = service.call(to_number: VALID_TO, body: "x" * 250, owner_id: "owner-1")

    assert result.ok?
  end

  def test_non_string_body_is_rejected_without_raising
    service, repository, gateway = build_service(gateway_result: success_result)

    result = service.call(to_number: VALID_TO, body: 12345, owner_id: "owner-1")

    refute result.ok?
    assert_equal ["must be a string"], result.errors[:body]
    assert_equal 0, gateway.calls.size
    assert_equal 0, repository.created_with.size
  end

  def test_both_invalid_to_number_and_body_report_both_errors
    service, = build_service(gateway_result: success_result)

    result = service.call(to_number: "", body: "", owner_id: "owner-1")

    refute result.ok?
    assert result.errors.key?(:to_number)
    assert result.errors.key?(:body)
  end
end

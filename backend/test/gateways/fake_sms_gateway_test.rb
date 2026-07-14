require_relative "../test_helper"
require "stringio"

class FakeSmsGatewayTest < Minitest::Test
  def setup
    @gateway = Gateways::FakeSmsGateway.new
  end

  def test_normal_send_returns_success_with_sm_prefixed_sid
    result = @gateway.send_sms(to: "+15551234567", body: "hello world")

    assert result.success
    assert_nil result.error
    refute_nil result.external_sid
    assert result.external_sid.start_with?("SM"), "expected SID to start with SM, got #{result.external_sid.inspect}"
  end

  def test_failure_simulation_number_returns_documented_failure
    result = @gateway.send_sms(to: Gateways::FakeSmsGateway::FAILURE_SIMULATION_NUMBER, body: "hello")

    refute result.success
    assert_nil result.external_sid
    refute_nil result.error
    assert_includes result.error, Gateways::FakeSmsGateway::FAILURE_SIMULATION_NUMBER
  end

  def test_different_numbers_yield_different_sids
    first = @gateway.send_sms(to: "+15551111111", body: "a")
    second = @gateway.send_sms(to: "+15552222222", body: "b")

    refute_equal first.external_sid, second.external_sid
  end

  # security-review-round1.md M5: raw body must never be logged, only its
  # length + metadata. Capture what actually gets logged and assert the
  # literal body text is absent while length metadata is present.
  def test_does_not_log_the_raw_message_body
    secret_body = "super-secret-pii-do-not-log-me-12345"
    captured = StringIO.new
    original_logger = Rails.logger
    Rails.instance_variable_set(:@logger, Logger.new(captured))

    begin
      @gateway.send_sms(to: "+15551234567", body: secret_body)
    ensure
      Rails.instance_variable_set(:@logger, original_logger)
    end

    logged = captured.string
    refute_includes logged, secret_body
    assert_includes logged, "body_length=#{secret_body.length}"
  end
end

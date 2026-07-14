require "securerandom"

module Gateways
  # Dev/test gateway (tech-design.md §4.3). Sends nothing over the network;
  # logs the attempted send and returns a deterministic-shaped fake result so
  # the whole send flow (service -> repository -> JSON response) is
  # demonstrable end-to-end before real Twilio credentials exist. This is the
  # default gateway everywhere until SMS_PROVIDER=twilio is set (see
  # config/initializers/container.rb).
  class FakeSmsGateway
    include SmsGatewayInterface

    # Documented failure-simulation hook: sending to this exact number always
    # returns success: false, so services/controllers/specs can exercise the
    # "sent -> failed, still persisted" path (tech-design.md §5 step 4)
    # without needing a live provider that actually rejects a number.
    FAILURE_SIMULATION_NUMBER = "+10000000000".freeze

    def send_sms(to:, body:)
      if to == FAILURE_SIMULATION_NUMBER
        result = SmsGatewayInterface::Result.new(
          success: false,
          external_sid: nil,
          error: "FakeSmsGateway: simulated failure for #{FAILURE_SIMULATION_NUMBER}"
        )
        log_send(to: to, body: body, result: result)
        return result
      end

      result = SmsGatewayInterface::Result.new(
        success: true,
        external_sid: "SM#{SecureRandom.hex(16)}",
        error: nil
      )
      log_send(to: to, body: body, result: result)
      result
    end

    private

    # security-review-round1.md M5: message bodies are arbitrary user-typed
    # free text that can carry PII, so never write the raw body to logs (logs
    # are often shipped to third-party aggregators/retained indefinitely).
    # Log only metadata (destination + body length + fake sid), matching the
    # discipline already followed by TwilioSmsGateway, which logs nothing at
    # all about the message content or credentials.
    def log_send(to:, body:, result:)
      Rails.logger.info(
        "[FakeSmsGateway] to=#{to} body_length=#{body.to_s.length} " \
        "success=#{result.success} external_sid=#{result.external_sid.inspect}"
      )
    end
  end
end

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
      Rails.logger.info("[FakeSmsGateway] to=#{to} body=#{body.inspect}")

      if to == FAILURE_SIMULATION_NUMBER
        return SmsGatewayInterface::Result.new(
          success: false,
          external_sid: nil,
          error: "FakeSmsGateway: simulated failure for #{FAILURE_SIMULATION_NUMBER}"
        )
      end

      SmsGatewayInterface::Result.new(
        success: true,
        external_sid: "SM#{SecureRandom.hex(16)}",
        error: nil
      )
    end
  end
end

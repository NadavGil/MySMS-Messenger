module Gateways
  # Documented contract for outbound SMS sending (tech-design.md §4.1,
  # HLD §4.4). Both FakeSmsGateway and TwilioSmsGateway `include` this so the
  # container/service layer can swap them by configuration alone; neither
  # controllers nor services ever touch a concrete gateway class directly.
  module SmsGatewayInterface
    # Value object every gateway returns, regardless of provider.
    #
    # success:      Boolean - whether the provider accepted the send.
    # external_sid: String|nil - provider-assigned message id (Twilio SID,
    #               or a "SM<hex>" id from FakeSmsGateway); nil on failure.
    # error:        String|nil - human-readable failure reason; nil on success.
    Result = Struct.new(:success, :external_sid, :error, keyword_init: true)

    # @param to [String] destination phone number, E.164 (validated upstream
    #   by the service layer - gateways do not re-validate format).
    # @param body [String] message text (already length-checked upstream).
    # @return [Result]
    def send_sms(to:, body:)
      raise NotImplementedError, "#{self.class} must implement #send_sms"
    end
  end
end

module Gateways
  # Real SMS gateway (tech-design.md §4.2). Reads credentials from ENV only -
  # never hardcoded - and is selected via SMS_PROVIDER=twilio
  # (config/initializers/container.rb). CityHive has not supplied live Twilio
  # credentials yet, so this class is untested against the real API this
  # pass (tracked as a risk in HLD §9); it is exercised in specs with a
  # stubbed Twilio::REST::Client only.
  class TwilioSmsGateway
    include SmsGatewayInterface

    def initialize(client: nil)
      @client = client || build_client
    end

    def send_sms(to:, body:)
      message = @client.messages.create(from: from_number, to: to, body: body)
      SmsGatewayInterface::Result.new(success: true, external_sid: message.sid, error: nil)
    rescue Twilio::REST::RestError => e
      SmsGatewayInterface::Result.new(success: false, external_sid: nil, error: e.message)
    end

    private

    def build_client
      Twilio::REST::Client.new(account_sid, auth_token)
    end

    def account_sid
      ENV.fetch("TWILIO_ACCOUNT_SID")
    end

    def auth_token
      ENV.fetch("TWILIO_AUTH_TOKEN")
    end

    def from_number
      ENV.fetch("TWILIO_FROM_NUMBER")
    end
  end
end

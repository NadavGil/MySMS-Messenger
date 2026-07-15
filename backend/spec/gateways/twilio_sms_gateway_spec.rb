# Plain-Ruby spec: no live Twilio calls. `twilio-ruby` itself is not
# required/loaded here — TwilioSmsGateway is injected a plain double in
# place of Twilio::REST::Client (the class already supports this via
# `TwilioSmsGateway.new(client:)`), and `Twilio::REST::RestError` is stubbed
# as a bare StandardError subclass since we only need `#message` on it.
# Closes MAJ4 from doc/code-review-iteration-1.md.
#
# Run with: bundle exec rspec spec/gateways/twilio_sms_gateway_spec.rb
# (bundler/twilio-ruby/rspec were unavailable in the sandbox used to author
# this spec — smoke-tested instead with a disposable plain-Ruby script; see
# the fix-up report.)
require "spec_helper"
require_relative "../../app/gateways/sms_gateway_interface"

module Twilio
  module REST
    class RestError < StandardError; end
  end
end

require_relative "../../app/gateways/twilio_sms_gateway"

RSpec.describe Gateways::TwilioSmsGateway do
  let(:fake_messages) { double("messages") }
  let(:fake_client) { double("Twilio::REST::Client", messages: fake_messages) }

  around do |example|
    original_sid = ENV["TWILIO_ACCOUNT_SID"]
    original_token = ENV["TWILIO_AUTH_TOKEN"]
    original_from = ENV["TWILIO_FROM_NUMBER"]
    original_callback = ENV["TWILIO_STATUS_CALLBACK_URL"]
    example.run
  ensure
    ENV["TWILIO_ACCOUNT_SID"] = original_sid
    ENV["TWILIO_AUTH_TOKEN"] = original_token
    ENV["TWILIO_FROM_NUMBER"] = original_from
    ENV["TWILIO_STATUS_CALLBACK_URL"] = original_callback
  end

  describe "#send_sms with an injected client (no ENV/credential path exercised)" do
    subject(:gateway) { described_class.new(client: fake_client) }

    it "delegates to client.messages.create with from/to/body and maps a successful response" do
      # from_number reads ENV via ENV.fetch (no default), so set it before
      # the expectation is set up. Explicitly unset so this test is
      # deterministic regardless of any real .env value (Bonus 3, §15.7).
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"
      ENV.delete("TWILIO_STATUS_CALLBACK_URL")

      twilio_message = double("Twilio::Message", sid: "SM_REAL_SID")
      expect(fake_messages).to receive(:create)
        .with(from: "+15005550006", to: "+14155550123", body: "hi")
        .and_return(twilio_message)

      result = gateway.send_sms(to: "+14155550123", body: "hi")

      expect(result.success).to eq(true)
      expect(result.external_sid).to eq("SM_REAL_SID")
      expect(result.error).to be_nil
    end

    # Bonus 3 (tech-design.md §15.7).
    it "forwards status_callback to client.messages.create when TWILIO_STATUS_CALLBACK_URL is set" do
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"
      ENV["TWILIO_STATUS_CALLBACK_URL"] = "https://mysms-messenger-server.onrender.com/api/v1/webhooks/twilio/status"

      twilio_message = double("Twilio::Message", sid: "SM_REAL_SID")
      expect(fake_messages).to receive(:create)
        .with(
          from: "+15005550006",
          to: "+14155550123",
          body: "hi",
          status_callback: "https://mysms-messenger-server.onrender.com/api/v1/webhooks/twilio/status"
        )
        .and_return(twilio_message)

      gateway.send_sms(to: "+14155550123", body: "hi")
    end

    # Bonus 3 (tech-design.md §15.7).
    it "omits status_callback entirely when TWILIO_STATUS_CALLBACK_URL is unset" do
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"
      ENV.delete("TWILIO_STATUS_CALLBACK_URL")

      twilio_message = double("Twilio::Message", sid: "SM_REAL_SID")
      expect(fake_messages).to receive(:create) do |**kwargs|
        expect(kwargs).not_to have_key(:status_callback)
        twilio_message
      end

      gateway.send_sms(to: "+14155550123", body: "hi")
    end

    it "maps a Twilio::REST::RestError into a failed Result with the error message, not a raise" do
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"
      allow(fake_messages).to receive(:create).and_raise(Twilio::REST::RestError, "The number is unreachable")

      result = nil
      expect { result = gateway.send_sms(to: "+14155550123", body: "hi") }.not_to raise_error

      expect(result.success).to eq(false)
      expect(result.external_sid).to be_nil
      expect(result.error).to eq("The number is unreachable")
    end
  end

  describe "reading credentials from ENV when no client is injected" do
    it "raises a clear KeyError (via ENV.fetch) when TWILIO_ACCOUNT_SID is missing" do
      ENV.delete("TWILIO_ACCOUNT_SID")
      ENV["TWILIO_AUTH_TOKEN"] = "token"
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"

      expect { described_class.new }.to raise_error(KeyError, /TWILIO_ACCOUNT_SID/)
    end

    it "raises a clear KeyError when TWILIO_AUTH_TOKEN is missing" do
      ENV["TWILIO_ACCOUNT_SID"] = "AC123"
      ENV.delete("TWILIO_AUTH_TOKEN")
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"

      expect { described_class.new }.to raise_error(KeyError, /TWILIO_AUTH_TOKEN/)
    end

    it "builds a real Twilio::REST::Client using ENV credentials when both are present" do
      ENV["TWILIO_ACCOUNT_SID"] = "AC123"
      ENV["TWILIO_AUTH_TOKEN"] = "token123"
      ENV["TWILIO_FROM_NUMBER"] = "+15005550006"

      fake_twilio_client = double("Twilio::REST::Client")
      client_class = double("Twilio::REST::Client class")
      stub_const("Twilio::REST::Client", client_class)
      expect(client_class).to receive(:new).with("AC123", "token123").and_return(fake_twilio_client)

      gateway = described_class.new

      expect(gateway.instance_variable_get(:@client)).to equal(fake_twilio_client)
    end

    it "does not read TWILIO_FROM_NUMBER until a send is attempted (from_number is lazy)" do
      ENV["TWILIO_ACCOUNT_SID"] = "AC123"
      ENV["TWILIO_AUTH_TOKEN"] = "token123"
      ENV.delete("TWILIO_FROM_NUMBER")

      fake_twilio_client = double("Twilio::REST::Client")
      client_class = double("Twilio::REST::Client class")
      stub_const("Twilio::REST::Client", client_class)
      allow(client_class).to receive(:new).and_return(fake_twilio_client)

      # Constructing the gateway itself must not require TWILIO_FROM_NUMBER.
      expect { described_class.new }.not_to raise_error
    end
  end
end

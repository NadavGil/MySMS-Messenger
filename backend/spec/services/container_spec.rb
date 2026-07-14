require "spec_helper"
require "ostruct"
require_relative "../../app/repositories/message_repository_interface"
require_relative "../../app/repositories/in_memory_message_repository"
require_relative "../../app/domain/message"

# Plain-Ruby spec: proves the container swaps implementations based on
# Rails.configuration.x, without booting the full Rails app. We fake just
# enough of `Rails` to exercise Services::Container's resolution logic
# (tech-design.md §2.6 / CP3 acceptance criteria: "spec proves swap").
module Repositories
  # Stand-ins for classes not yet introduced at CP3 (real ones land with the
  # Mongo integration / Twilio CP4 work); only used so `.constantize.new`
  # has something real to resolve to in this spec.
end

module Gateways
  class FakeSmsGateway
    def send_sms(to:, body:); :fake_result; end
  end

  class TwilioSmsGateway
    def send_sms(to:, body:); :twilio_result; end
  end
end

RSpec.describe "Services::Container resolution" do
  before do
    stub_const("Rails", Class.new do
      def self.configuration
        @configuration ||= OpenStruct.new(x: OpenStruct.new)
      end
    end)

    # Load config/initializers/container.rb's resolution logic directly
    # against our faked Rails, mirroring what the real initializer does.
    load File.expand_path("../../app/services/container.rb", __dir__)
  end

  def resolve!(message_repository:, sms_gateway:)
    Rails.configuration.x.message_repository_class = message_repository
    Rails.configuration.x.sms_gateway_class = sms_gateway
  end

  it "resolves the in_memory repository when configured" do
    resolve!(message_repository: "Repositories::InMemoryMessageRepository", sms_gateway: "Gateways::FakeSmsGateway")

    expect(Services::Container.message_repository).to be_a(Repositories::InMemoryMessageRepository)
  end

  it "resolves the fake gateway when configured" do
    resolve!(message_repository: "Repositories::InMemoryMessageRepository", sms_gateway: "Gateways::FakeSmsGateway")

    expect(Services::Container.sms_gateway).to be_a(Gateways::FakeSmsGateway)
  end

  it "resolves the twilio gateway when configured (config-only swap, no code change)" do
    resolve!(message_repository: "Repositories::InMemoryMessageRepository", sms_gateway: "Gateways::TwilioSmsGateway")

    expect(Services::Container.sms_gateway).to be_a(Gateways::TwilioSmsGateway)
  end
end

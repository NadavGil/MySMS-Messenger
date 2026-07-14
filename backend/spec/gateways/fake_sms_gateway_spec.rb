require "spec_helper"
require_relative "../../app/gateways/sms_gateway_interface"
require_relative "../../app/gateways/fake_sms_gateway"

# Plain-Ruby spec (no Rails boot needed) - stub the one Rails call the
# gateway makes (Rails.logger) so this runs standalone like the other
# app/repositories specs (tech-design.md §7).
RSpec.describe Gateways::FakeSmsGateway do
  before do
    fake_logger = Object.new
    def fake_logger.info(*); end
    stub_const("Rails", Class.new { define_singleton_method(:logger) { Object.new.tap { |l| def l.info(*); end } } })
  end

  subject(:gateway) { described_class.new }

  it "returns a successful result with a fake SID for a normal number" do
    result = gateway.send_sms(to: "+14155550123", body: "hello")

    expect(result.success).to eq(true)
    expect(result.external_sid).to match(/\ASM[0-9a-f]{32}\z/)
    expect(result.error).to be_nil
  end

  it "simulates a failure for the documented failure number" do
    result = gateway.send_sms(to: Gateways::FakeSmsGateway::FAILURE_SIMULATION_NUMBER, body: "hello")

    expect(result.success).to eq(false)
    expect(result.external_sid).to be_nil
    expect(result.error).to be_a(String)
  end
end

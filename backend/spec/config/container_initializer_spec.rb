require "spec_helper"
require "ostruct"

# Plain-Ruby spec for config/initializers/container.rb itself: proves the
# ENV-driven defaulting is correct per environment (tech-design.md §2.6 /
# CP3 acceptance criteria: "defaults correct per env"). Fakes just enough of
# `Rails` to load the initializer standalone, without booting the app.
RSpec.describe "config/initializers/container.rb" do
  def run_initializer!(env_name:, env_vars: {})
    fake_rails = Class.new do
      def self.configuration
        @configuration ||= OpenStruct.new(x: OpenStruct.new)
      end
    end
    fake_rails.define_singleton_method(:env) do
      OpenStruct.new(test?: env_name == "test")
    end
    stub_const("Rails", fake_rails)

    original_env = ENV.to_hash
    ENV.replace(env_vars)
    load File.expand_path("../../../config/initializers/container.rb", __dir__)
    Rails.configuration.x
  ensure
    ENV.replace(original_env)
  end

  it "defaults to the in_memory repository in the test environment" do
    x = run_initializer!(env_name: "test")
    expect(x.message_repository_class).to eq("Repositories::InMemoryMessageRepository")
  end

  it "defaults to the mongo repository outside the test environment" do
    x = run_initializer!(env_name: "development")
    expect(x.message_repository_class).to eq("Repositories::MongoMessageRepository")
  end

  it "honors MESSAGE_REPOSITORY=in_memory even outside test" do
    x = run_initializer!(env_name: "development", env_vars: { "MESSAGE_REPOSITORY" => "in_memory" })
    expect(x.message_repository_class).to eq("Repositories::InMemoryMessageRepository")
  end

  it "defaults the sms gateway to fake absent SMS_PROVIDER" do
    x = run_initializer!(env_name: "development")
    expect(x.sms_gateway_class).to eq("Gateways::FakeSmsGateway")
  end

  it "honors SMS_PROVIDER=twilio (config-only swap) when credentials are present" do
    x = run_initializer!(env_name: "development", env_vars: {
      "SMS_PROVIDER" => "twilio",
      "TWILIO_ACCOUNT_SID" => "ACxxxx",
      "TWILIO_AUTH_TOKEN" => "token",
      "TWILIO_FROM_NUMBER" => "+15550000000"
    })
    expect(x.sms_gateway_class).to eq("Gateways::TwilioSmsGateway")
  end

  it "raises on an unknown MESSAGE_REPOSITORY value" do
    expect do
      run_initializer!(env_name: "development", env_vars: { "MESSAGE_REPOSITORY" => "postgres" })
    end.to raise_error(ArgumentError, /Unknown MESSAGE_REPOSITORY/)
  end

  # CP11: SMS_PROVIDER=twilio must fail loudly at boot, not on first send,
  # when Twilio credentials are not configured (qa/security round1 flagged
  # this exact gap as a "pre-loaded landmine" for CP11).
  it "raises a clear startup error when SMS_PROVIDER=twilio but credentials are missing" do
    expect do
      run_initializer!(env_name: "development", env_vars: { "SMS_PROVIDER" => "twilio" })
    end.to raise_error(ArgumentError, /SMS_PROVIDER=twilio but missing required ENV var/)
  end

  it "raises naming only the specific missing Twilio credential(s)" do
    expect do
      run_initializer!(env_name: "development", env_vars: {
        "SMS_PROVIDER" => "twilio",
        "TWILIO_ACCOUNT_SID" => "ACxxxx"
      })
    end.to raise_error(ArgumentError, /TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER/)
  end
end

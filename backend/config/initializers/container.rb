# IoC wiring (tech-design.md §2.6). No DI gem: this initializer resolves
# concrete class names from ENV (with per-environment defaults) and stashes
# them on Rails.configuration.x. app/services/container.rb turns those
# strings into instances so controllers/services stay one-liners.
#
# Swapping implementations is config-only:
#   MESSAGE_REPOSITORY=in_memory bin/rails server
#   SMS_PROVIDER=twilio bin/rails server
# ...changes wiring with zero code edits.

# Resolve the repository implementation.
repo_choice = ENV.fetch("MESSAGE_REPOSITORY", Rails.env.test? ? "in_memory" : "mongo")
Rails.configuration.x.message_repository_class =
  {
    "mongo" => "Repositories::MongoMessageRepository",
    "in_memory" => "Repositories::InMemoryMessageRepository"
  }.fetch(repo_choice) do
    raise ArgumentError, "Unknown MESSAGE_REPOSITORY=#{repo_choice.inspect}; expected 'mongo' or 'in_memory'"
  end

# Resolve the SMS gateway implementation.
# Default is "fake" everywhere until real Twilio creds exist (locked in
# tech-design.md §2.6) — this is intentionally NOT env-dependent like the
# repository default, since the fake gateway is safe to use in every
# environment absent explicit opt-in.
provider_choice = ENV.fetch("SMS_PROVIDER", "fake")
Rails.configuration.x.sms_gateway_class =
  {
    "twilio" => "Gateways::TwilioSmsGateway",
    "fake" => "Gateways::FakeSmsGateway"
  }.fetch(provider_choice) do
    raise ArgumentError, "Unknown SMS_PROVIDER=#{provider_choice.inspect}; expected 'fake' or 'twilio'"
  end

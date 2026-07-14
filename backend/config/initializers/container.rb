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

# CP11: fail loudly at boot, not on the first request, if the real Twilio
# gateway is selected without its required credentials. TwilioSmsGateway
# itself uses ENV.fetch (no defaults) for TWILIO_ACCOUNT_SID/AUTH_TOKEN/
# FROM_NUMBER, so a missing var would eventually raise a bare KeyError the
# first time someone actually sends a message - checking here instead gives
# a single, clear, actionable startup error naming exactly which var(s) are
# missing, before the app ever accepts traffic.
if provider_choice == "twilio"
  required_twilio_vars = %w[TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_FROM_NUMBER]
  missing_twilio_vars = required_twilio_vars.reject { |var| !ENV[var].nil? && !ENV[var].empty? }

  if missing_twilio_vars.any?
    raise ArgumentError,
          "SMS_PROVIDER=twilio but missing required ENV var(s): #{missing_twilio_vars.join(', ')}. " \
          "Set these (see .env.example) before starting the app with the real Twilio gateway."
  end
end

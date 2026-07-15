# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# Bug blitz (2026-07-15) finding: Gateways::FakeSmsGateway deliberately never
# logs the raw message body (security-review-round1.md M5), but that
# discipline wasn't carried through to the framework-level request logger —
# ActionController::LogSubscriber logs the full `Parameters: {...}` hash for
# every request by default, and POST /api/v1/messages' `body`/`to_number`
# were not in this filter list, so the same SMS content/PII was leaking into
# production logs anyway via the standard Rails request log line.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :auth_token, :account_sid, :body, :to_number
]

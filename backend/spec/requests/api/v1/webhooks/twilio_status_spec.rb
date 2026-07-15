require "rails_helper"

# Request spec for POST /api/v1/webhooks/twilio/status (tech-design.md
# §15.5/§15.9/§15.10, CP24 acceptance criteria). Exercises the full
# behavior matrix: 503 when unconfigured, 403 on a bad/missing signature,
# 200 no-op on an unknown SID or unstored status, and 200 + persisted
# status change on a valid known callback. Runs with
# MESSAGE_REPOSITORY=in_memory (tech-design.md §15.10) so no Mongo is
# required.
#
# Builds a GENUINELY valid X-Twilio-Signature rather than bypassing
# validation, using Twilio's publicly documented algorithm directly
# (HMAC-SHA1 of the callback URL + sorted-and-concatenated param
# key/value pairs, base64-encoded) instead of calling into twilio-ruby's
# RequestValidator internals, since the exact private/public surface of
# that gem could not be verified in this sandbox (no rubygems.org access
# - see the standing limitation noted throughout this repo). The
# production controller under test still uses the real
# Twilio::Security::RequestValidator#validate (a documented public
# method) to verify the signature this spec builds.
#
# NOTE: requires a full Rails boot (bundle install, incl. twilio-ruby) to
# execute; this sandbox has no network access to install gems, so this
# spec is hand-authored and unexecuted here, matching every other request
# spec in this suite. See report for what could vs. couldn't run.
RSpec.describe "POST /api/v1/webhooks/twilio/status", type: :request do
  let(:callback_url) { "https://mysms-messenger-server.onrender.com/api/v1/webhooks/twilio/status" }
  let(:auth_token) { "test_auth_token_123" }

  around do |example|
    original_token = ENV["TWILIO_AUTH_TOKEN"]
    original_callback = ENV["TWILIO_STATUS_CALLBACK_URL"]
    ENV["TWILIO_STATUS_CALLBACK_URL"] = callback_url
    example.run
  ensure
    ENV["TWILIO_AUTH_TOKEN"] = original_token
    ENV["TWILIO_STATUS_CALLBACK_URL"] = original_callback
  end

  # Twilio's documented request-validation algorithm (used only to build a
  # genuinely valid signature for these specs - see file header).
  def twilio_signature_for(url, params, token)
    data = +url
    params.sort.each { |key, value| data << key.to_s << value.to_s }
    digest = OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha1"), token, data)
    Base64.strict_encode64(digest)
  end

  def post_status_callback(params:, token: auth_token, sign: true)
    headers = {}
    if sign
      headers["X-Twilio-Signature"] = twilio_signature_for(callback_url, params, token)
    end
    post "/api/v1/webhooks/twilio/status", params: params, headers: headers
  end

  describe "when TWILIO_AUTH_TOKEN is blank (current default - no live Twilio creds)" do
    it "returns 503 and never attempts signature validation" do
      ENV.delete("TWILIO_AUTH_TOKEN")

      post_status_callback(params: { MessageSid: "SIDX", MessageStatus: "delivered" }, sign: false)

      expect(response).to have_http_status(:service_unavailable)
    end

    it "returns 503 even when a well-formed signature header is present" do
      ENV.delete("TWILIO_AUTH_TOKEN")

      post_status_callback(params: { MessageSid: "SIDX", MessageStatus: "delivered" }, token: "irrelevant")

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  # qa-security-review-bonus3-webhooks.md M1: TWILIO_AUTH_TOKEN set without
  # TWILIO_STATUS_CALLBACK_URL used to raise an uncaught KeyError (an
  # unstructured 500) instead of the intended clean 503. Fixed by guarding
  # both together; this proves the fix and guards against a regression.
  describe "when TWILIO_AUTH_TOKEN is set but TWILIO_STATUS_CALLBACK_URL is not" do
    it "returns 503, not a 500, and never raises" do
      ENV["TWILIO_AUTH_TOKEN"] = auth_token
      ENV.delete("TWILIO_STATUS_CALLBACK_URL")

      expect {
        post "/api/v1/webhooks/twilio/status",
             params: { MessageSid: "SIDX", MessageStatus: "delivered" },
             headers: { "X-Twilio-Signature" => "anything" }
      }.not_to raise_error

      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "when TWILIO_AUTH_TOKEN is configured" do
    before { ENV["TWILIO_AUTH_TOKEN"] = auth_token }

    it "returns 403 when X-Twilio-Signature is missing" do
      post "/api/v1/webhooks/twilio/status", params: { MessageSid: "SIDX", MessageStatus: "delivered" }

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 when the signature is present but invalid" do
      post "/api/v1/webhooks/twilio/status",
           params: { MessageSid: "SIDX", MessageStatus: "delivered" },
           headers: { "X-Twilio-Signature" => "not-a-real-signature" }

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 when signed with the wrong auth token" do
      post_status_callback(
        params: { MessageSid: "SIDX", MessageStatus: "delivered" },
        token: "a-completely-different-token"
      )

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 200 (safe no-op) for an unknown MessageSid, even with a valid signature" do
      post_status_callback(params: { MessageSid: "NO_SUCH_SID", MessageStatus: "delivered" })

      expect(response).to have_http_status(:ok)
    end

    it "returns 200 (no-op) for a transient status not in STATUSES, e.g. 'sending'" do
      # Create a real message so we can prove its status is untouched.
      Services::Container.message_repository.create(
        to_number: "+14155550123", body: "hi", owner_id: "owner-1",
        status: "sent", external_sid: "SID_SENDING"
      )

      post_status_callback(params: { MessageSid: "SID_SENDING", MessageStatus: "sending" })
      expect(response).to have_http_status(:ok)

      message = Services::Container.message_repository.find_for_owner("owner-1").first
      expect(message.status).to eq("sent") # unchanged - "sending" is not persisted
    end

    it "returns 200 and persists the new status for a known SID + valid signature" do
      Services::Container.message_repository.create(
        to_number: "+14155550123", body: "hi", owner_id: "owner-2",
        status: "sent", external_sid: "SID_KNOWN"
      )

      post_status_callback(params: { MessageSid: "SID_KNOWN", MessageStatus: "delivered" })

      expect(response).to have_http_status(:ok)
      message = Services::Container.message_repository.find_for_owner("owner-2").first
      expect(message.status).to eq("delivered")
    end

    it "is idempotent: a duplicate callback for the same SID is harmless" do
      Services::Container.message_repository.create(
        to_number: "+14155550123", body: "hi", owner_id: "owner-3",
        status: "sent", external_sid: "SID_DUPLICATE"
      )

      2.times { post_status_callback(params: { MessageSid: "SID_DUPLICATE", MessageStatus: "delivered" }) }

      expect(response).to have_http_status(:ok)
      message = Services::Container.message_repository.find_for_owner("owner-3").first
      expect(message.status).to eq("delivered")
    end

    it "supports the legacy SmsSid/SmsStatus param names" do
      Services::Container.message_repository.create(
        to_number: "+14155550123", body: "hi", owner_id: "owner-4",
        status: "sent", external_sid: "SID_LEGACY"
      )

      post_status_callback(params: { SmsSid: "SID_LEGACY", SmsStatus: "undelivered" })

      expect(response).to have_http_status(:ok)
      message = Services::Container.message_repository.find_for_owner("owner-4").first
      expect(message.status).to eq("undelivered")
    end

    it "does not require the :msms_owner auth cookie (Twilio cannot hold one)" do
      post_status_callback(params: { MessageSid: "NO_SUCH_SID", MessageStatus: "delivered" })

      expect(response).not_to have_http_status(:unauthorized)
    end
  end
end

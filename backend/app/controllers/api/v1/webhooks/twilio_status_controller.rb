module Api
  module V1
    module Webhooks
      # Bonus 3 (tech-design.md §15.5). Inbound Twilio delivery-status
      # webhook - a server-to-server integration surface, NOT part of the
      # SPA API contract. Twilio cannot hold the :msms_owner cookie, so this
      # controller opts out of the auth gate (mirrors HealthController) and
      # authenticates the caller via Twilio's request signature instead.
      class TwilioStatusController < ApplicationController
        skip_before_action :resolve_current_identity

        # POST /api/v1/webhooks/twilio/status
        def create
          # (a) DISABLED when unconfigured: no signing secret means we
          # cannot verify anyone, so reject everything rather than accept
          # unsigned requests. This is the SMS_PROVIDER=fake / no-creds
          # posture today, and also protects against someone flipping
          # SMS_PROVIDER=twilio without also setting TWILIO_AUTH_TOKEN.
          # 503 (not 200) so a misconfiguration is visible, not silent.
          #
          # QA FIX (qa-security-review-bonus3-webhooks.md M1): also require
          # TWILIO_STATUS_CALLBACK_URL here, not just TWILIO_AUTH_TOKEN. The
          # original draft only guarded on auth_token and read the callback
          # URL via ENV.fetch (no default) inside valid_twilio_signature? -
          # if AUTH_TOKEN were ever set without also setting the callback
          # URL, that fetch would raise an uncaught KeyError -> an
          # unstructured 500 instead of a clean 503, on every single
          # request to this endpoint. Guarding both together at the top
          # keeps the "disabled means disabled" contract airtight.
          return head :service_unavailable if auth_token.blank? || callback_url.blank?

          # (b) AUTHENTICATE the caller as Twilio via request signature.
          return head :forbidden unless valid_twilio_signature?

          sid    = params[:MessageSid] || params[:SmsSid]
          status = (params[:MessageStatus] || params[:SmsStatus]).to_s

          # (c) Only write a whitelisted status for a known SID. Unknown
          # SID, an unstored/transient status (e.g. "sending"), or missing
          # params => no-op. update_status_by_external_sid itself already
          # returns nil (safe no-op) on an unknown SID.
          if sid.present? && MessageDocument::STATUSES.include?(status)
            Services::Container.message_repository
                               .update_status_by_external_sid(sid, status)
          end

          # (d) ALWAYS 200 on an authenticated call (even a no-op) so Twilio
          # stops retrying. A genuine DB outage still surfaces as 503 via
          # ApplicationController's rescue_from RepositoryError - Twilio's
          # retry is the desired behavior in that case.
          head :ok
        end

        private

        def auth_token
          ENV["TWILIO_AUTH_TOKEN"] # already read by TwilioSmsGateway
        end

        def valid_twilio_signature?
          signature = request.headers["X-Twilio-Signature"].to_s
          return false if signature.empty?

          Twilio::Security::RequestValidator.new(auth_token)
            .validate(callback_url, request.request_parameters, signature)
        end

        # Validate against the EXACT configured callback URL rather than
        # reconstructing the request URL behind Render's TLS-terminating
        # proxy (tech-design.md §15.6) - because we set status_callback: to
        # exactly this URL on the outbound send (§15.7), it is by
        # construction the exact URL Twilio calls and signs, sidestepping
        # all X-Forwarded-Proto/X-Forwarded-Host reconstruction fragility.
        # Read via ENV[] (not ENV.fetch) so a missing value is `nil`/blank
        # rather than an uncaught KeyError - the `create` action's combined
        # blank? guard above is what actually enforces "must be configured".
        def callback_url
          ENV["TWILIO_STATUS_CALLBACK_URL"]
        end
      end
    end
  end
end

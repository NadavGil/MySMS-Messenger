# Rate limiting (security-review-round1.md H1 — the single most important
# action item from that review). Sending a real SMS via Twilio costs money
# per message, and the only "auth" in front of POST /api/v1/messages is a
# self-issued signed cookie (CurrentIdentity) — anyone can mint unlimited
# identities (clear cookies / curl without cookies) and hammer the send
# endpoint. This throttle protects against that cost-abuse scenario, which
# becomes a real financial exposure the moment SMS_PROVIDER=twilio is set
# with live credentials (today's default, SMS_PROVIDER=fake, is otherwise
# the only thing standing between this code and unbounded spend).
class Rack::Attack
  # Keep throttling out of the test suite (specs fire many requests in
  # quick succession on purpose) and allow it to be killed via ENV in any
  # environment if it ever needs an emergency bypass.
  unless Rails.env.test? || ActiveModel::Type::Boolean.new.cast(ENV["RACK_ATTACK_DISABLED"])
    throttle("messages/send/owner_id", limit: 10, period: 60) do |req|
      next unless req.post? && req.path == "/api/v1/messages"

      # Key by owner_id (the signed CurrentIdentity cookie) so throttling
      # tracks the same identity the app itself uses for scoping, not just
      # an IP that many legitimate users could share (NAT/office network).
      # Fall back to IP when the cookie is absent/invalid/unsigned (e.g. a
      # curl request with no cookie jar at all) so that path is still
      # bounded rather than exempt.
      owner_id_from_signed_cookie(req) || req.ip
    end

    # Brute-force protection for POST /api/v1/auth/login (tech-design.md
    # §13.6). Keyed by IP (MY CALL, per tech design): the JSON body isn't
    # parsed at middleware time, so keying by IP + attempted username would
    # require req.body.read + rewind, which is fragile with the JSON parser
    # downstream. IP-only is the pragmatic, correct-by-default choice.
    throttle("auth/login/ip", limit: 5, period: 60) do |req|
      req.ip if req.post? && req.path == "/api/v1/auth/login"
    end
  end

  def self.owner_id_from_signed_cookie(req)
    # Rack::Attack hands us a Rack::Request; wrap it in ActionDispatch::Request
    # to get access to the signed cookie jar the same way CurrentIdentity does.
    ActionDispatch::Request.new(req.env).cookie_jar.signed[:msms_owner]
  rescue StandardError
    nil
  end

  self.throttled_responder = lambda do |request|
    [
      429,
      { "Content-Type" => "application/json" },
      [{ errors: { base: ["Too many requests. Please slow down and try again shortly."] } }.to_json]
    ]
  end
end

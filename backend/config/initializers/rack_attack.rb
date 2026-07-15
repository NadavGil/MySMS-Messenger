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

    # qa-security-review-bonus1-auth.md M2/M3: signup was completely
    # unthrottled, and its 422 "username already taken" response is a clean,
    # unbounded username-enumeration oracle (cheaper/more precise than the
    # login-timing side-channel M1 addresses) - also a plain account-creation
    # abuse vector (spam accounts / Mongo write cost) on its own. Keyed by IP
    # (same reasoning as auth/login/ip: body isn't parsed at middleware
    # time). Limit is looser than login (10 vs 5) since signup is a
    # legitimate, if infrequent, one-time action per real user and false
    # positives here are more costly (blocks a brand-new user from ever
    # joining) than on login (where a real user can just retry a password).
    throttle("auth/signup/ip", limit: 10, period: 60) do |req|
      req.ip if req.post? && req.path == "/api/v1/auth/signup"
    end

    # Bonus 3 (tech-design.md §15.8): coarse pre-auth abuse guard for the
    # Twilio status webhook. Generous (60/min) since Twilio legitimately
    # sends many callbacks; this exists to blunt abuse from non-Twilio
    # sources hammering the endpoint before the signature check even runs -
    # it is not the primary control (the signature is). Keyed by IP (no
    # cookie/owner to key on here).
    throttle("webhooks/twilio/ip", limit: 60, period: 60) do |req|
      req.ip if req.post? && req.path == "/api/v1/webhooks/twilio/status"
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

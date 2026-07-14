require "securerandom"

# Session/identity concern (tech-design.md §2.7, HLD §4.5). Answers "who
# owns this request?" via a signed, HttpOnly cookie — a stable per-browser
# identifier issued on first contact and read thereafter. No login in this
# pass; this is the seam Bonus 1 (auth) later re-points to a real User id
# without touching Message storage/scoping.
module CurrentIdentity
  extend ActiveSupport::Concern

  included do
    before_action :resolve_current_identity
  end

  private

  COOKIE = :msms_owner

  def resolve_current_identity
    @current_identity = cookies.signed[COOKIE]

    unless @current_identity.present?
      # RACE CONDITION (qa-report-round1.md M3, security-review-round1.md
      # I4/M3 context): if two "first contact" requests from the same
      # browser arrive close enough together that neither has the cookie
      # yet (e.g. the SPA firing an initial GET refresh and a POST send in
      # parallel before any Set-Cookie round-trips), each one mints its own
      # SecureRandom.uuid here independently. Whichever response's
      # Set-Cookie the browser applies last "wins", and any message written
      # under the discarded owner_id becomes permanently invisible to that
      # browser. Cookie-based identity issued from stateless request
      # handlers is inherently racy for this narrow window — there's no
      # request-scoped lock across concurrent connections without adding a
      # shared, synchronous "claim an identity" step server-side (e.g. a
      # dedicated bootstrap endpoint the SPA awaits before firing parallel
      # calls), which is more machinery than this pass's scope justifies.
      # ACCEPTED LIMITATION: documented here rather than engineered around;
      # revisit if Bonus 1 (real auth/login) replaces cookie-only identity.
      @current_identity = SecureRandom.uuid
      cookies.signed[COOKIE] = {
        value: @current_identity,
        httponly: true,
        same_site: same_site_policy,
        secure: secure_cookie?,
        expires: 1.year.from_now
      }
    end
  end

  attr_reader :current_identity

  # SameSite/Secure policy (qa-report-round1.md M1, security-review-round1.md
  # M3): the default `same_site: :lax` only works when the SPA and API are
  # treated as same-site by the browser (true for localhost:4200 ->
  # localhost:3000 in dev, since SameSite ignores port). The instant the SPA
  # and API are deployed on genuinely different registrable domains (HLD §8 /
  # Bonus 2), `Lax` cookies are withheld from the SPA's fetch/XHR calls and
  # CurrentIdentity silently mints a fresh identity on every request.
  #
  # Trade-off: `SameSite=None` is required for real cross-origin credentialed
  # requests, but browsers additionally require `Secure` (HTTPS-only) for any
  # `SameSite=None` cookie — so this path only makes sense once the
  # deployment actually terminates TLS. We gate it behind an explicit ENV
  # flag (CROSS_ORIGIN_COOKIES=true) rather than inferring it from
  # Rails.env, so:
  #   - same-origin/dev/staging setups keep the simpler, no-HTTPS-required
  #     `:lax` behavior by default (zero config needed);
  #   - a genuine cross-origin production deployment opts in explicitly and
  #     is expected to also serve HTTPS (config.force_ssl = true already set
  #     in config/environments/production.rb covers this).
  def same_site_policy
    cross_origin_cookies? ? :none : :lax
  end

  def secure_cookie?
    # `SameSite=None` cookies are rejected by browsers unless `Secure` is
    # also set, so cross-origin mode forces `secure: true` regardless of
    # environment. Otherwise fall back to the previous production-only rule.
    cross_origin_cookies? || Rails.env.production?
  end

  def cross_origin_cookies?
    ActiveModel::Type::Boolean.new.cast(ENV["CROSS_ORIGIN_COOKIES"]) == true
  end
end

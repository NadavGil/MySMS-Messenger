# Session/identity concern (tech-design.md §2.7, §13.3, HLD §4.5). Answers
# "who owns this request?" via a signed, HttpOnly cookie. Bonus 1 (auth)
# re-points this from a self-minted anonymous UUID to a real, authenticated
# User id — the cookie infrastructure (same_site/secure/cross-origin policy)
# carries over verbatim; only WHAT gets validated/stored changed.
module CurrentIdentity
  extend ActiveSupport::Concern

  included do
    before_action :resolve_current_identity
  end

  private

  COOKIE = :msms_owner

  # REQUIRES a valid, still-existing authenticated user id in the signed
  # cookie. No silent identity minting (that was the pre-auth behavior; see
  # git history on this file for the superseded implementation and its
  # documented race-condition caveat, now moot since login is a synchronous,
  # explicit step rather than "first contact").
  def resolve_current_identity
    user_id = cookies.signed[COOKIE]
    @current_user = User.where(id: user_id).first if user_id.present?
    return if @current_user # authenticated

    render json: { errors: { base: ["Not authenticated"] } }, status: :unauthorized
  end

  attr_reader :current_user
  # Backwards-compatible alias: MessagesController still calls
  # `current_identity` and expects the owner_id STRING it has always scoped
  # Message#owner_id by (tech-design.md §13.1 — zero schema/service changes).
  def current_identity = @current_user&.id&.to_s

  # Called by AuthController on signup/login. Cookie contents = the User id
  # STRING (nothing else). All flag logic below is UNCHANGED from §2.7.
  def sign_in(user)
    @current_user = user
    cookies.signed[COOKIE] = {
      value: user.id.to_s, httponly: true,
      same_site: same_site_policy, secure: secure_cookie?,
      expires: 1.year.from_now
    }
  end

  def sign_out
    cookies.delete(COOKIE, same_site: same_site_policy, secure: secure_cookie?)
    @current_user = nil
  end

  # SameSite/Secure policy (qa-report-round1.md M1, security-review-round1.md
  # M3): the default `same_site: :lax` only works when the SPA and API are
  # treated as same-site by the browser (true for localhost:4200 ->
  # localhost:3000 in dev, since SameSite ignores port). The instant the SPA
  # and API are deployed on genuinely different registrable domains (HLD §8 /
  # Bonus 2), `Lax` cookies are withheld from the SPA's fetch/XHR calls.
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

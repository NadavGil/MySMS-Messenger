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
      @current_identity = SecureRandom.uuid
      cookies.signed[COOKIE] = {
        value: @current_identity,
        httponly: true,
        same_site: :lax,
        secure: Rails.env.production?,
        expires: 1.year.from_now
      }
    end
  end

  attr_reader :current_identity
end

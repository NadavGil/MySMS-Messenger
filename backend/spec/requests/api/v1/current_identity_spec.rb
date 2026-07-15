require "rails_helper"

# Request spec proving CurrentIdentity's CURRENT, auth-required contract
# (tech-design.md §13.3/§2.7, CP15 acceptance criteria: "request spec proves
# 401 unauthenticated and scoping when authed"). Bonus 1 re-pointed
# CurrentIdentity from a self-minted anonymous cookie to a real,
# authenticated User id (see current_identity.rb) - it no longer issues any
# cookie on first contact, and unauthenticated requests to any endpoint that
# does NOT skip the before_action now 401.
#
# qa-security-review-bonus1-auth.md H1/NIT1: the previous version of this
# file asserted the OLD anonymous-cookie-minting behavior against /health
# and was stale/would fail against the current code (and /health itself has
# since been fixed, C1/B1, to explicitly skip auth entirely - so it is no
# longer a useful "goes through CurrentIdentity" example endpoint). This
# rewrite uses GET /api/v1/auth/me, which intentionally does NOT skip the
# before_action (auth_controller.rb: "the before_action's 401 IS its 'not
# logged in' answer"), so it's the correct minimal endpoint to prove the
# auth-required contract against.
#
# NOTE: requires a full Rails boot (bundle install) to execute; this
# sandbox has no network access to install gems (Rails/Mongoid/bcrypt/etc.
# are not installed here), so this spec is hand-authored and unexecuted in
# this environment - see qa-security-review-bonus1-auth.md and the report
# for details. It has been written to be internally consistent with the
# actual current controller/model code (read, not assumed).
RSpec.describe "CurrentIdentity", type: :request do
  def signup!(username: "alice", password: "correct-horse-battery")
    post "/api/v1/auth/signup", params: { username: username, password: password }
  end

  it "401s an unauthenticated request instead of minting an anonymous identity" do
    get "/api/v1/auth/me"

    expect(response).to have_http_status(:unauthorized)
    body = JSON.parse(response.body)
    expect(body["errors"]["base"]).to be_present
    expect(response.cookies["msms_owner"]).to be_nil
  end

  it "authenticates the request once a real signed cookie is present (signup sets it)" do
    signup!

    get "/api/v1/auth/me"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["username"]).to eq("alice")
  end

  it "keeps the same identity across requests as long as the session cookie is sent back" do
    signup!

    get "/api/v1/auth/me"
    first_id = JSON.parse(response.body)["id"]

    get "/api/v1/auth/me"
    second_id = JSON.parse(response.body)["id"]

    expect(second_id).to eq(first_id)
  end

  it "does not authenticate a fresh session that never logged in, even after another session did" do
    signup!(username: "alice")

    reset! if respond_to?(:reset!) # clears the test session's cookie jar
    get "/api/v1/auth/me"

    expect(response).to have_http_status(:unauthorized)
  end

  it "GET /health still works with no cookie at all (C1/B1 fix - health is exempt from auth)" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["status"]).to eq("ok")
  end
end

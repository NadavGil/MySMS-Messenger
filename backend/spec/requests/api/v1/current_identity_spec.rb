require "rails_helper"

# Request spec proving CurrentIdentity's contract (tech-design.md §2.7 / CP5
# acceptance criteria: "request spec proves stable id across requests").
# Uses /health (CP1) as a neutral endpoint that goes through
# ApplicationController -> CurrentIdentity without depending on the
# messages endpoints (CP6/CP7, not yet implemented).
#
# NOTE: requires a full Rails boot (bundle install) to execute; this
# sandbox has no network access to install gems, so this spec is
# hand-authored and unexecuted here — see report for details.
RSpec.describe "CurrentIdentity", type: :request do
  it "issues a signed owner cookie on first contact" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.cookies["msms_owner"]).to be_present
  end

  it "keeps the same identity across requests when the cookie is sent back" do
    get "/health"
    first_cookie = response.cookies["msms_owner"]

    get "/health", headers: { "Cookie" => "msms_owner=#{first_cookie}" }
    second_cookie = response.cookies["msms_owner"] || first_cookie

    expect(second_cookie).to eq(first_cookie)
  end

  it "issues different identities for two independent sessions" do
    get "/health"
    identity_a = response.cookies["msms_owner"]

    reset! if respond_to?(:reset!) # clears the test session's cookie jar
    get "/health"
    identity_b = response.cookies["msms_owner"]

    expect(identity_a).not_to eq(identity_b)
  end
end

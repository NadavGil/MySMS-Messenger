require "rails_helper"

# Request spec for GET /api/v1/messages (tech-design.md §6.2 / CP7
# acceptance criteria: newest-first, count, scoped-to-owner, cross-user
# isolation) - updated for the Bonus 1 auth-required contract.
#
# qa-security-review-bonus1-auth.md H1/MAJ2: the previous version of this
# spec exercised the OLD anonymous-cookie-swap mechanism ("owner A" was just
# "whatever cookie jar happened to be active"), which (a) is stale against
# the current auth-required CurrentIdentity and (b) never actually proved
# the authorization boundary with two REAL, distinct authenticated users -
# a gap the review flagged (MAJ2) as still open even conceptually under the
# new model. This rewrite signs up two real users (alice, bob) and asserts
# bob's GET /api/v1/messages never includes alice's message.
#
# NOTE: requires a full Rails boot (bundle install) to execute; this
# sandbox has no network access to install gems, so this spec is
# hand-authored and unexecuted here - logic verified via the plain-Ruby
# Minitest suite for the framework-independent service/repository layer
# (see backend/test/, which does execute). See report for details.
RSpec.describe "GET /api/v1/messages", type: :request do
  def sign_up_and_in!(username:, password: "correct-horse-battery")
    post "/api/v1/auth/signup", params: { username: username, password: password }
    raise "signup failed in spec setup: #{response.body}" unless response.status == 201
  end

  it "401s when there is no authenticated user at all" do
    get "/api/v1/messages"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns count and messages newest-first for the authenticated user" do
    sign_up_and_in!(username: "alice")

    post "/api/v1/messages", params: { to_number: "+14155550111", body: "first" }
    post "/api/v1/messages", params: { to_number: "+14155550222", body: "second" }

    get "/api/v1/messages"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body["count"]).to eq(2)
    expect(body["messages"].map { |m| m["body"] }).to eq(["second", "first"])
  end

  it "scopes results to the authenticated user only - a real second user sees nothing of the first's (MAJ2)" do
    sign_up_and_in!(username: "alice")
    post "/api/v1/messages", params: { to_number: "+14155550111", body: "owner A's message" }

    reset! if respond_to?(:reset!) # new cookie jar - alice is no longer signed in here
    sign_up_and_in!(username: "bob")

    get "/api/v1/messages"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["count"]).to eq(0)
    expect(body["messages"]).to eq([])
  end

  it "does not leak one user's messages into another authenticated user's list even when both have sent messages" do
    sign_up_and_in!(username: "alice")
    post "/api/v1/messages", params: { to_number: "+14155550111", body: "alice's message" }

    reset! if respond_to?(:reset!)
    sign_up_and_in!(username: "bob")
    post "/api/v1/messages", params: { to_number: "+14155550222", body: "bob's message" }

    get "/api/v1/messages"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["count"]).to eq(1)
    expect(body["messages"].map { |m| m["body"] }).to eq(["bob's message"])
  end
end

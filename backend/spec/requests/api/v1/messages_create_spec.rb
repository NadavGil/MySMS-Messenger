require "rails_helper"

# Request spec for POST /api/v1/messages (tech-design.md §6.1 / CP6
# acceptance criteria, updated for the Bonus 1 auth-required contract).
# Runs with the test-environment defaults (MESSAGE_REPOSITORY=in_memory,
# SMS_PROVIDER=fake) so no Mongo/network is required (tech-design.md §7).
#
# qa-security-review-bonus1-auth.md H1: the previous version of this file
# asserted the OLD anonymous-cookie-minting contract (POST succeeding with
# no prior login). Under the current CurrentIdentity (auth-required), an
# unauthenticated POST now 401s - MessagesController#create is not in
# CurrentIdentity's skip list, so every example below signs a real user in
# first via POST /api/v1/auth/signup before exercising the endpoint.
#
# NOTE: requires a full Rails boot (bundle install) to execute; this
# sandbox has no network access to install gems, so this spec is
# hand-authored and unexecuted here - logic was verified with a plain-Ruby
# smoke script against SendMessageService + InMemoryMessageRepository +
# gateways directly (see backend/test/ Minitest suite, which does execute).
# See report for details.
RSpec.describe "POST /api/v1/messages", type: :request do
  def sign_up_and_in!(username: "alice", password: "correct-horse-battery")
    post "/api/v1/auth/signup", params: { username: username, password: password }
    raise "signup failed in spec setup: #{response.body}" unless response.status == 201
  end

  it "401s when there is no authenticated user at all" do
    post "/api/v1/messages", params: { to_number: "+14155550123", body: "Hello there" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "creates and persists a message, returning 201 with the documented shape" do
    sign_up_and_in!

    post "/api/v1/messages", params: { to_number: "+14155550123", body: "Hello there" }

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)

    expect(body["to_number"]).to eq("+14155550123")
    expect(body["body"]).to eq("Hello there")
    expect(body["status"]).to eq("sent")
    expect(body["external_sid"]).to start_with("SM")
    expect(body["id"]).to be_present
    expect(body["created_at"]).to be_present
  end

  it "returns 422 with field errors for an invalid to_number" do
    sign_up_and_in!

    post "/api/v1/messages", params: { to_number: "not-a-number", body: "Hello" }

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["errors"]["to_number"]).to be_present
  end

  it "returns 422 with field errors when body exceeds 250 characters" do
    sign_up_and_in!

    post "/api/v1/messages", params: { to_number: "+14155550123", body: "a" * 251 }

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["errors"]["body"]).to be_present
  end

  it "still persists the message with status failed when the gateway send fails" do
    sign_up_and_in!

    post "/api/v1/messages", params: {
      to_number: Gateways::FakeSmsGateway::FAILURE_SIMULATION_NUMBER,
      body: "will fail"
    }

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["status"]).to eq("failed")
    expect(body["external_sid"]).to be_nil
  end

  it "stamps the message with the authenticated user's id as owner_id (verified indirectly via GET in CP7)" do
    sign_up_and_in!

    post "/api/v1/messages", params: { to_number: "+14155550123", body: "hi" }
    expect(response).to have_http_status(:created)
    expect(response.cookies["msms_owner"]).to be_present
  end
end

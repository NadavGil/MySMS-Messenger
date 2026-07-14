require "rails_helper"

# Request spec for POST /api/v1/messages (tech-design.md §6.1 / CP6
# acceptance criteria). Runs with the test-environment defaults
# (MESSAGE_REPOSITORY=in_memory, SMS_PROVIDER=fake) so no Mongo/network is
# required (tech-design.md §7).
#
# NOTE: requires a full Rails boot (bundle install) to execute; this
# sandbox has no network access to install gems, so this spec is
# hand-authored and unexecuted here (same limitation as CP5's
# current_identity_spec.rb) - logic was verified with a plain-Ruby smoke
# script against SendMessageService + InMemoryMessageRepository + gateways
# directly. See report for details.
RSpec.describe "POST /api/v1/messages", type: :request do
  it "creates and persists a message, returning 201 with the documented shape" do
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
    post "/api/v1/messages", params: { to_number: "not-a-number", body: "Hello" }

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["errors"]["to_number"]).to be_present
  end

  it "returns 422 with field errors when body exceeds 250 characters" do
    post "/api/v1/messages", params: { to_number: "+14155550123", body: "a" * 251 }

    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["errors"]["body"]).to be_present
  end

  it "still persists the message with status failed when the gateway send fails" do
    post "/api/v1/messages", params: {
      to_number: Gateways::FakeSmsGateway::FAILURE_SIMULATION_NUMBER,
      body: "will fail"
    }

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["status"]).to eq("failed")
    expect(body["external_sid"]).to be_nil
  end

  it "stamps the message with the current identity's owner_id (verified indirectly via GET in CP7)" do
    post "/api/v1/messages", params: { to_number: "+14155550123", body: "hi" }
    expect(response).to have_http_status(:created)
    expect(response.cookies["msms_owner"]).to be_present
  end
end

require "rails_helper"

# Request spec for GET /api/v1/messages (tech-design.md §6.2 / CP7
# acceptance criteria: newest-first, count, scoped-to-owner, cross-session
# isolation). Same unexecuted-in-sandbox caveat as messages_create_spec.rb -
# logic verified via a plain-Ruby smoke script against ListMessagesService +
# InMemoryMessageRepository directly (see report).
RSpec.describe "GET /api/v1/messages", type: :request do
  it "returns count and messages newest-first for the current identity" do
    post "/api/v1/messages", params: { to_number: "+14155550111", body: "first" }
    post "/api/v1/messages", params: { to_number: "+14155550222", body: "second" }

    get "/api/v1/messages"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body["count"]).to eq(2)
    expect(body["messages"].map { |m| m["body"] }).to eq(["second", "first"])
  end

  it "scopes results to the current identity only - a fresh session sees nothing" do
    post "/api/v1/messages", params: { to_number: "+14155550111", body: "owner A's message" }

    reset! if respond_to?(:reset!) # new cookie jar -> new owner_id
    get "/api/v1/messages"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["count"]).to eq(0)
    expect(body["messages"]).to eq([])
  end
end

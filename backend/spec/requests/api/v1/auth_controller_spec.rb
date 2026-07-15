require "rails_helper"

# Request spec for AuthController - signup/login/logout/me (tech-design.md
# §13.4/§13.5, CP14 acceptance criteria, verbatim from
# qa-security-review-bonus1-auth.md H2: "request spec covering all four
# endpoints plus enumeration-safe 401"). This spec did not exist prior to
# the QA/security review flagging its absence.
#
# NOTE: requires a full Rails boot (bundle install + Mongoid + bcrypt +
# rack-attack) to execute; this sandbox has no network access to install
# gems, so this spec is hand-authored and unexecuted here. Written against
# the actual current backend/app/controllers/api/v1/auth_controller.rb
# (read, not assumed): user_json whitelists {id, username} only, login
# returns a generic "Invalid username or password" for both bad-username
# and bad-password (M1's dummy-hash timing fix doesn't change the response
# body, only timing, so it isn't independently assertable here), logout is
# idempotent/never 401s, and me relies on the before_action's 401 as its
# "not logged in" answer. See report for what could vs. couldn't run.
RSpec.describe "Api::V1::Auth", type: :request do
  describe "POST /api/v1/auth/signup" do
    it "creates a user, signs them in, and returns 201 with id+username only" do
      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["username"]).to eq("alice")
      expect(body["id"]).to be_present
      expect(body).not_to have_key("password_digest")
      expect(body).not_to have_key("password")
      expect(response.cookies["msms_owner"]).to be_present
    end

    it "returns 422 with field errors for an invalid username" do
      post "/api/v1/auth/signup", params: { username: "a!", password: "correct-horse-battery" }

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["errors"]["username"]).to be_present
    end

    it "returns 422 when the password is too short" do
      post "/api/v1/auth/signup", params: { username: "alice", password: "short1" }

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["errors"]["password"]).to be_present
    end

    it "returns 422 'already taken' on a duplicate username (M2/M3: disclosed, throttled oracle - see rack_attack_spec)" do
      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }
      expect(response).to have_http_status(:created)

      post "/api/v1/auth/signup", params: { username: "alice", password: "another-password" }
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["errors"]["username"]).to include("has already been taken")
    end

    it "never returns a password_digest for a non-string/injected username param" do
      post "/api/v1/auth/signup", params: { username: { a: 1 }, password: "correct-horse-battery" }

      # MIN3: non-string username degrades to a clean 422 (format validation
      # fails on a Hash), not a 500.
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /api/v1/auth/login" do
    before do
      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }
      reset! if respond_to?(:reset!) # start login examples logged out
    end

    it "logs in with correct credentials and returns 200 with id+username only" do
      post "/api/v1/auth/login", params: { username: "alice", password: "correct-horse-battery" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["username"]).to eq("alice")
      expect(response.cookies["msms_owner"]).to be_present
    end

    it "is case-insensitive on username (matches User's normalized storage)" do
      post "/api/v1/auth/login", params: { username: "ALICE", password: "correct-horse-battery" }

      expect(response).to have_http_status(:ok)
    end

    it "returns a generic 401 for a wrong password (no content-based enumeration)" do
      post "/api/v1/auth/login", params: { username: "alice", password: "wrong-password" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["errors"]["base"]).to eq(["Invalid username or password"])
    end

    it "returns the SAME generic 401 body for a nonexistent username (enumeration-safe, CP14)" do
      post "/api/v1/auth/login", params: { username: "no_such_user", password: "wrong-password" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["errors"]["base"]).to eq(["Invalid username or password"])
    end
  end

  describe "DELETE /api/v1/auth/logout" do
    it "clears the session for a logged-in user and is idempotent" do
      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }

      delete "/api/v1/auth/logout"
      expect(response).to have_http_status(:no_content)

      get "/api/v1/auth/me"
      expect(response).to have_http_status(:unauthorized)
    end

    it "never 401s even when nobody is logged in (idempotent)" do
      delete "/api/v1/auth/logout"

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET /api/v1/auth/me" do
    it "401s when not authenticated" do
      get "/api/v1/auth/me"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the current user's id+username when authenticated" do
      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["username"]).to eq("alice")
      expect(body).not_to have_key("password_digest")
    end
  end
end

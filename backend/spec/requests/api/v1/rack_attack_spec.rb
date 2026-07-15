require "rails_helper"

# Request spec proving the rack-attack throttles actually 429 (tech-design.md
# §13.6, CP16 acceptance criteria, verbatim from
# qa-security-review-bonus1-auth.md H2: "a rack-attack spec proving the 6th
# login attempt 429s"). Also covers the signup throttle added in response to
# M2/M3 (config/initializers/rack_attack.rb: "auth/signup/ip", limit 10/60s).
#
# Rack::Attack's rules in this app are wrapped in
# `unless Rails.env.test? || RACK_ATTACK_DISABLED` (see rack_attack.rb) so
# that the OTHER request specs in this suite - which fire many requests in
# quick succession on purpose - don't get throttled. That means these two
# specific examples need Rack::Attack re-armed for the duration of the
# example: stub Rails.env.test? to false and re-evaluate the initializer so
# the `throttle` blocks actually get registered, then restore/reset
# afterwards. This is the standard rack-attack testing idiom (see the
# rack-attack gem's own README "Testing" section) applied to this app's
# test-env-disables-throttling wrinkle.
#
# NOTE: requires a full Rails boot (bundle install + rack-attack gem) to
# execute; this sandbox has no network access to install gems, so this spec
# is hand-authored and unexecuted here. See report for what could vs.
# couldn't run.
RSpec.describe "Rack::Attack throttles", type: :request do
  around do |example|
    Rack::Attack.reset! # clear any cached counts from a previous example
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    allow(Rails.env).to receive(:test?).and_return(false)
    load Rails.root.join("config/initializers/rack_attack.rb") # re-register throttle blocks

    example.run
  ensure
    Rack::Attack.reset!
  end

  describe "POST /api/v1/auth/login (5/60s per IP)" do
    it "429s on the 6th attempt from the same IP within the window" do
      5.times do
        post "/api/v1/auth/login", params: { username: "no_such_user", password: "wrong" }
        expect(response).to have_http_status(:unauthorized)
      end

      post "/api/v1/auth/login", params: { username: "no_such_user", password: "wrong" }

      expect(response).to have_http_status(:too_many_requests)
      body = JSON.parse(response.body)
      expect(body["errors"]["base"]).to be_present
    end
  end

  describe "POST /api/v1/auth/signup (10/60s per IP, M2/M3 fix)" do
    it "429s on the 11th attempt from the same IP within the window" do
      10.times do |i|
        post "/api/v1/auth/signup", params: { username: "user#{i}", password: "correct-horse-battery" }
      end

      post "/api/v1/auth/signup", params: { username: "user_overflow", password: "correct-horse-battery" }

      expect(response).to have_http_status(:too_many_requests)
    end

    it "throttles duplicate-username probing just as effectively as new signups (M3: closes the free enumeration oracle)" do
      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }
      expect(response).to have_http_status(:created)

      9.times do
        post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }
      end

      post "/api/v1/auth/signup", params: { username: "alice", password: "correct-horse-battery" }

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end

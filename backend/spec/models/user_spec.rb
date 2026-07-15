require "rails_helper"

# Model spec for User (tech-design.md §13.2, CP13 acceptance criteria,
# verbatim from qa-security-review-bonus1-auth.md H2: "digest set not
# plaintext, `authenticate` works, dup username rejected"). This spec did
# not exist prior to the QA/security review flagging its absence (H2) -
# CP13 was checked off in the tech design without an actual spec landing
# alongside it.
#
# NOTE: requires a full Rails boot (bundle install + Mongoid + bcrypt) to
# execute; this sandbox has no network access to install gems, so this
# spec is hand-authored and unexecuted here. It has been written against
# the actual current backend/app/models/user.rb (read, not assumed):
# has_secure_password, `username` normalized to downcase/strip before
# validation, format /\A[a-z0-9_]{3,30}\z/, uniqueness, and a minimum
# password length of 8. See report for what could vs. couldn't run.
RSpec.describe User, type: :model do
  def build_user(username: "alice", password: "correct-horse-battery")
    User.new(username: username, password: password)
  end

  describe "has_secure_password" do
    it "stores a bcrypt digest, never the plaintext password" do
      user = build_user(password: "correct-horse-battery")
      user.save!

      expect(user.password_digest).to be_present
      expect(user.password_digest).not_to eq("correct-horse-battery")
      expect(user.password_digest).to start_with("$2") # bcrypt digest prefix
    end

    it "authenticates with the correct password" do
      user = build_user(password: "correct-horse-battery")
      user.save!

      expect(user.authenticate("correct-horse-battery")).to eq(user)
    end

    it "does not authenticate with an incorrect password" do
      user = build_user(password: "correct-horse-battery")
      user.save!

      expect(user.authenticate("wrong-password")).to eq(false)
    end
  end

  describe "username uniqueness" do
    it "rejects a duplicate username" do
      build_user(username: "alice").save!
      dup = build_user(username: "alice")

      expect(dup).not_to be_valid
      expect(dup.errors[:username]).to include("has already been taken")
    end

    it "treats usernames as case-insensitive duplicates (normalized to lowercase)" do
      build_user(username: "Alice").save!
      dup = build_user(username: "ALICE")

      expect(dup).not_to be_valid
      expect(dup.errors[:username]).to include("has already been taken")
    end
  end

  describe "username normalization" do
    it "downcases and strips the username before validation" do
      user = build_user(username: "  AliceInChains  ")
      user.valid?

      expect(user.username).to eq("aliceinchains")
    end
  end

  describe "username format" do
    it "accepts 3-30 chars of lowercase letters, digits, underscore" do
      expect(build_user(username: "abc")).to be_valid
      expect(build_user(username: "a" * 30)).to be_valid
      expect(build_user(username: "user_name_1")).to be_valid
    end

    it "rejects usernames shorter than 3 chars" do
      expect(build_user(username: "ab")).not_to be_valid
    end

    it "rejects usernames longer than 30 chars" do
      expect(build_user(username: "a" * 31)).not_to be_valid
    end

    it "rejects usernames with characters outside [a-z0-9_]" do
      expect(build_user(username: "alice!")).not_to be_valid
      expect(build_user(username: "alice bob")).not_to be_valid
    end

    it "is anchored (\\A/\\z) so an embedded newline can't smuggle invalid characters past a naive ^/$ check" do
      expect(build_user(username: "alice\nrm -rf /")).not_to be_valid
    end

    it "rejects a blank username" do
      expect(build_user(username: "")).not_to be_valid
      expect(build_user(username: nil)).not_to be_valid
    end
  end

  describe "password length" do
    it "rejects a password shorter than 8 characters" do
      user = build_user(password: "short1")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "accepts an 8+ character password" do
      expect(build_user(password: "eightch4rs")).to be_valid
    end
  end
end

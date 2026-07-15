# Real, EXECUTABLE Minitest coverage for the one piece of User's logic
# (backend/app/models/user.rb) that is genuinely framework-independent:
# the username format regex and the downcase/strip normalization applied
# in `before_validation`.
#
# The rest of User (has_secure_password/bcrypt, Mongoid::Document,
# uniqueness validation against a real index) CANNOT be loaded or run in
# this sandbox - `require "user"` would need Mongoid + bcrypt + ActiveModel,
# none of which are installed here (no network access to rubygems.org; see
# test_helper.rb's own note re: FakeSmsGateway needing a Rails.logger stub
# for the same reason). Those paths are instead covered by
# backend/spec/models/user_spec.rb (RSpec, hand-authored, unexecuted in
# this sandbox - see qa-security-review-bonus1-auth.md H2 and the report).
#
# To keep THIS test honest (not a hand-copied regex that can silently
# drift from the real one), the format regex is extracted directly from
# user.rb's actual source text rather than retyped here, so a future change
# to the real regex is picked up automatically. The downcase/strip
# normalization has no equivalent extraction trick (it's a block, not a
# literal), so that piece IS a duplicate of the real logic - called out
# explicitly below and in the report.
require_relative "../test_helper"

class UserNormalizationTest < Minitest::Test
  USER_MODEL_PATH = File.expand_path("../../app/models/user.rb", __dir__)
  USER_SOURCE = File.read(USER_MODEL_PATH)

  def format_regex
    match = USER_SOURCE.match(/format:\s*\{\s*with:\s*(\/.*?\/)/)
    raise "could not find username format regex in #{USER_MODEL_PATH} - has the model changed shape?" unless match

    eval(match[1]) # rubocop:disable Security/Eval -- test-only, evaluating a regex literal read from our own repo's source, not external input
  end

  # Duplicate of user.rb's `before_validation { self.username =
  # username.downcase.strip if username.is_a?(String) }` - the callback
  # itself can't be invoked without Mongoid/ActiveModel loaded, so this
  # mirrors the same two method calls it's known to make.
  def normalize(username)
    return username unless username.is_a?(String)

    username.downcase.strip
  end

  def test_format_regex_is_anchored_with_A_and_z_not_caret_dollar
    source = format_regex.source
    assert_includes source, "\\A", "regex should use \\A (not ^) to resist embedded-newline bypass"
    assert_includes source, "\\z", "regex should use \\z (not $) to resist embedded-newline bypass"
  end

  def test_format_regex_accepts_valid_usernames
    assert_match format_regex, "abc"
    assert_match format_regex, "a" * 30
    assert_match format_regex, "user_name_1"
    assert_match format_regex, "123"
  end

  def test_format_regex_rejects_too_short
    refute_match format_regex, "ab"
  end

  def test_format_regex_rejects_too_long
    refute_match format_regex, "a" * 31
  end

  def test_format_regex_rejects_uppercase
    refute_match format_regex, "Alice"
  end

  def test_format_regex_rejects_special_characters
    refute_match format_regex, "alice!"
    refute_match format_regex, "alice bob"
    refute_match format_regex, "alice@bob"
  end

  def test_format_regex_rejects_embedded_newline_bypass_attempt
    # With ^/$ (not \A/\z), "alice\nbogus" could match line-by-line. Confirm
    # the anchors actually reject it end-to-end.
    refute_match format_regex, "alice\nrm -rf /"
  end

  def test_normalize_downcases
    assert_equal "alice", normalize("ALICE")
  end

  def test_normalize_strips_whitespace
    assert_equal "alice", normalize("  alice  ")
  end

  def test_normalize_downcases_and_strips_together
    assert_equal "aliceinchains", normalize("  AliceInChains  ")
  end

  def test_normalize_is_a_noop_on_non_string_input
    hash_input = { a: 1 }
    assert_equal hash_input, normalize(hash_input)
  end

  def test_normalized_username_then_satisfies_the_format_regex
    normalized = normalize("  AliceInChains  ")
    assert_match format_regex, normalized
  end
end

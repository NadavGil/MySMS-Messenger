# Standalone runner: requires every *_test.rb file under backend/test/ and
# lets Minitest::autorun (loaded via test_helper, required by each test
# file) execute them all in a single process.
#
# Usage (from repo root):
#   ruby backend/test/run_all.rb
require_relative "test_helper"

Dir.glob(File.join(__dir__, "**", "*_test.rb")).sort.each { |f| require f }

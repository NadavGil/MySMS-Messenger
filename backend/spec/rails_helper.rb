# This file is loaded by specs that need a full Rails environment (e.g.
# request specs added at CP6/CP7). Plain-Ruby specs (repositories, domain
# objects) should require "spec_helper" only so they can run without booting
# Rails/Mongoid (tech-design.md §7).
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rspec/rails"

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Services::Container now memoizes InMemoryMessageRepository as a
  # per-process singleton (fix for qa-report-round1.md Blocker B1) so state
  # survives across requests within one running app - but that means, in
  # this same RSpec process, records would otherwise leak from one example
  # into the next. Reset the memoized instance before every example so each
  # request-spec example still gets an isolated, empty in-memory store.
  config.before(:each) do
    Services::Container.reset!
  end
end

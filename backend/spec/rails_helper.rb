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
end

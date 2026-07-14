require "spec_helper"
require "securerandom"
require_relative "../../app/repositories/message_repository_interface"
require_relative "../../app/repositories/in_memory_message_repository"
require_relative "../../app/domain/message"
require_relative "../support/shared_examples/message_repository_examples"

# Plain-Ruby spec: no Rails boot, no Mongo, no bundle required beyond rspec
# itself (tech-design.md §7 / CP2 acceptance criteria). Run with:
#   bundle exec rspec spec/repositories/in_memory_message_repository_spec.rb
RSpec.describe Repositories::InMemoryMessageRepository do
  subject(:repository) { described_class.new }

  it_behaves_like "a message repository"

  it "isolates state between separate instances" do
    other = described_class.new
    repository.create(to_number: "+14155550123", body: "hi", owner_id: "a")

    expect(other.find_for_owner("a")).to eq([])
  end

  describe "#clear!" do
    it "empties the store (test helper, not part of the interface)" do
      repository.create(to_number: "+14155550123", body: "hi", owner_id: "a")
      repository.clear!

      expect(repository.find_for_owner("a")).to eq([])
    end
  end
end

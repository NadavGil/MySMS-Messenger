# Plain-Ruby spec: no Rails boot, no Mongo required (tech-design.md §7).
# Closes MAJ3 from doc/code-review-iteration-1.md for ListMessagesService.
#
# Run with: bundle exec rspec spec/services/list_messages_service_spec.rb
# (bundler/rspec were unavailable in the sandbox used to author this spec —
# see the send_message_service_spec.rb header and the fix-up report for how
# this was smoke-tested instead.)
require "spec_helper"
require_relative "../../app/domain/message"
require_relative "../../app/repositories/message_repository_interface"
require_relative "../../app/repositories/in_memory_message_repository"
require_relative "../../app/services/list_messages_service"

RSpec.describe Services::ListMessagesService do
  let(:repository) { Repositories::InMemoryMessageRepository.new }
  subject(:service) { described_class.new(repository: repository) }

  let(:owner_id) { "owner-1" }
  let(:other_owner_id) { "owner-2" }

  it "scopes results to the given owner_id, excluding other owners' messages" do
    mine = repository.create(to_number: "+14155550123", body: "mine", owner_id: owner_id)
    repository.create(to_number: "+14155550124", body: "not mine", owner_id: other_owner_id)

    results = service.call(owner_id: owner_id)

    expect(results.map(&:id)).to contain_exactly(mine.id)
  end

  it "returns messages newest-first" do
    first = repository.create(to_number: "+14155550123", body: "first", owner_id: owner_id)
    sleep 0.01
    second = repository.create(to_number: "+14155550123", body: "second", owner_id: owner_id)

    results = service.call(owner_id: owner_id)

    expect(results.map(&:id)).to eq([second.id, first.id])
  end

  it "returns an empty array when the owner has no messages" do
    expect(service.call(owner_id: owner_id)).to eq([])
  end

  it "returns an accurate count via the array size, matching the number of persisted messages for that owner" do
    3.times { |i| repository.create(to_number: "+14155550123", body: "msg #{i}", owner_id: owner_id) }
    repository.create(to_number: "+14155550123", body: "other owner's msg", owner_id: other_owner_id)

    results = service.call(owner_id: owner_id)

    expect(results.size).to eq(3)
  end
end

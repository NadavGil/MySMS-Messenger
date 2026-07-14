# Shared-example contract (tech-design.md §7): asserting parity between
# InMemoryMessageRepository and MongoMessageRepository. The Mongo-backed spec
# (tagged :mongo) is expected to `it_behaves_like "a message repository"` too,
# but is skipped in environments without a live Mongo instance.
#
# Deliberately avoids ActiveSupport-only matchers (e.g. `be_present`) so this
# file — and any plain-Ruby repository spec that includes it — can run under
# bare RSpec without a full Rails boot.
RSpec.shared_examples "a message repository" do
  let(:owner_id) { "owner-#{SecureRandom.uuid}" }
  let(:other_owner_id) { "owner-#{SecureRandom.uuid}" }

  let(:base_attrs) do
    { to_number: "+14155550123", body: "hello", owner_id: owner_id }
  end

  describe "#create" do
    it "returns a persisted Domain::Message with an id and created_at" do
      message = repository.create(base_attrs)

      expect(message).to be_a(Domain::Message)
      expect(message.id).not_to be_nil
      expect(message.to_number).to eq("+14155550123")
      expect(message.body).to eq("hello")
      expect(message.owner_id).to eq(owner_id)
      expect(message.created_at).not_to be_nil
    end

    it "defaults status to queued when not provided" do
      message = repository.create(base_attrs)
      expect(message.status).to eq("queued")
    end

    it "persists whatever status is explicitly given (e.g. failed sends)" do
      message = repository.create(base_attrs.merge(status: "failed"))
      expect(message.status).to eq("failed")
    end

    it "persists the external_sid when given" do
      message = repository.create(base_attrs.merge(external_sid: "SID123"))
      expect(message.external_sid).to eq("SID123")
    end
  end

  describe "#find_for_owner" do
    it "returns only messages belonging to the given owner" do
      mine = repository.create(base_attrs)
      repository.create(base_attrs.merge(owner_id: other_owner_id))

      results = repository.find_for_owner(owner_id)

      expect(results.map(&:id)).to contain_exactly(mine.id)
    end

    it "returns newest-first" do
      first = repository.create(base_attrs.merge(body: "first"))
      sleep 0.01
      second = repository.create(base_attrs.merge(body: "second"))

      results = repository.find_for_owner(owner_id)

      expect(results.map(&:id)).to eq([second.id, first.id])
    end

    it "returns an empty array when the owner has no messages" do
      expect(repository.find_for_owner(owner_id)).to eq([])
    end
  end
end

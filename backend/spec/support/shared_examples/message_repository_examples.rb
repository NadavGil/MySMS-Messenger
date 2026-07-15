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

    # Bug blitz (2026-07-15) follow-up: previously unbounded. Both
    # implementations share Repositories::MessageRepositoryInterface::
    # MAX_RESULTS_PER_OWNER as the cap so they can't drift out of sync. Only
    # asserting the size here (not which specific record got dropped) — with
    # cap+1 records created back-to-back in a tight loop, timestamps can tie
    # at whatever precision the backing store offers, and "returns
    # newest-first" (above) already covers ordering correctness on its own.
    it "caps results at MAX_RESULTS_PER_OWNER instead of returning everything" do
      cap = Repositories::MessageRepositoryInterface::MAX_RESULTS_PER_OWNER
      (cap + 1).times { |i| repository.create(base_attrs.merge(body: "msg-#{i}")) }

      expect(repository.find_for_owner(owner_id).size).to eq(cap)
    end
  end

  # Bonus 3 (tech-design.md §15.3).
  describe "#update_status_by_external_sid" do
    it "updates the status of the message with the matching external_sid" do
      message = repository.create(base_attrs.merge(external_sid: "SID123", status: "sent"))

      updated = repository.update_status_by_external_sid("SID123", "delivered")

      expect(updated).to be_a(Domain::Message)
      expect(updated.id).to eq(message.id)
      expect(updated.status).to eq("delivered")
    end

    it "persists the update (visible on a subsequent read)" do
      repository.create(base_attrs.merge(external_sid: "SID456", status: "sent"))

      repository.update_status_by_external_sid("SID456", "undelivered")

      persisted = repository.find_for_owner(owner_id).find { |m| m.external_sid == "SID456" }
      expect(persisted.status).to eq("undelivered")
    end

    it "returns nil (a safe no-op) when no message matches the external_sid" do
      expect(repository.update_status_by_external_sid("UNKNOWN_SID", "delivered")).to be_nil
    end

    it "does not affect other messages" do
      other = repository.create(base_attrs.merge(external_sid: "SID_OTHER", status: "sent"))

      repository.update_status_by_external_sid("SID_DIFFERENT", "delivered")

      untouched = repository.find_for_owner(owner_id).find { |m| m.id == other.id }
      expect(untouched.status).to eq("sent")
    end

    # Bug blitz (2026-07-15) follow-up: Twilio's callback delivery has no
    # ordering guarantee, so a delayed/retried callback must not regress an
    # already-more-advanced status backward.
    it "rejects a regressive update and leaves the current status intact" do
      repository.create(base_attrs.merge(external_sid: "SID_REGRESS", status: "sent"))
      repository.update_status_by_external_sid("SID_REGRESS", "delivered")

      result = repository.update_status_by_external_sid("SID_REGRESS", "sent")

      expect(result.status).to eq("delivered")
      persisted = repository.find_for_owner(owner_id).find { |m| m.external_sid == "SID_REGRESS" }
      expect(persisted.status).to eq("delivered")
    end

    it "rejects a same-rank update (no flip-flopping between terminal statuses)" do
      repository.create(base_attrs.merge(external_sid: "SID_SAME_RANK", status: "sent"))
      repository.update_status_by_external_sid("SID_SAME_RANK", "delivered")

      result = repository.update_status_by_external_sid("SID_SAME_RANK", "undelivered")

      expect(result.status).to eq("delivered")
    end

    it "still allows a genuinely forward update" do
      repository.create(base_attrs.merge(external_sid: "SID_FORWARD", status: "queued"))

      result = repository.update_status_by_external_sid("SID_FORWARD", "sent")

      expect(result.status).to eq("sent")
    end
  end
end

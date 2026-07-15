# KNOWN LIMITATION: this sandbox has no live MongoDB instance and cannot
# install the `mongoid`/`bson` gems (no bundler/network access here — see
# doc/code-review-iteration-1.md MAJ4). tech-design.md §7 anticipates this
# exact situation ("a shared-example ... runs against both InMemory and
# (optionally, tagged :mongo) Mongo impls") and explicitly allows the Mongo
# spec to be tagged `:mongo` and skipped when no live Mongo is available.
#
# Rather than skip entirely, this spec fakes just the two collaborators
# MongoMessageRepository actually talks to — `MessageDocument` (Mongoid
# model) and `Mongo::Error` (the driver's error class) — as plain Ruby
# doubles/classes, so the repository's own mapping/rescue logic (the part
# that is actually this class's responsibility, as opposed to Mongoid's
# internals) gets real coverage without a real Mongo connection. This is a
# fake-collaborator unit test, not an integration test against a real
# MongoDB — a true integration spec still belongs behind a `:mongo` tag once
# a real Mongo instance is reachable (e.g. via docker-compose in CI).
#
# Run with: bundle exec rspec spec/repositories/mongo_message_repository_spec.rb
# (bundler/mongoid were unavailable in the sandbox used to author this spec
# — smoke-tested instead with a disposable plain-Ruby script; see the
# fix-up report.)
require "spec_helper"
require_relative "../../app/domain/message"
require_relative "../../app/repositories/message_repository_interface"

module Mongo
  class Error < StandardError; end
end

# Bug blitz (2026-07-15) follow-up: fake standing in for the real
# Mongoid::Errors::Validation (raised by MessageDocument.create!/#update!
# when a document fails its own model validations — see that model's
# comments). Same rationale as the Mongo::Error fake above: the real
# mongoid gem is unavailable in this sandbox.
module Mongoid
  module Errors
    class Validation < StandardError; end
  end
end

# Minimal fake standing in for the real Rails.logger call inside
# MongoMessageRepository#raise_repository_error.
module Rails
  def self.logger
    @logger ||= Object.new.tap { |l| def l.error(*); end }
  end
end

require_relative "../../app/repositories/mongo_message_repository"

RSpec.describe Repositories::MongoMessageRepository do
  # Fake Mongoid document class standing in for the real `MessageDocument`.
  # A plain (non-verifying) double, not `class_double`, since the real
  # `MessageDocument` constant (a Mongoid model) is never loaded in this
  # sandbox — see the KNOWN LIMITATION note at the top of this file.
  let(:document_class) { double("MessageDocument class") }

  before do
    stub_const("MessageDocument", document_class)
  end

  subject(:repository) { described_class.new }

  let(:base_attrs) { { to_number: "+14155550123", body: "hello", owner_id: "owner-1" } }

  describe "#create" do
    it "maps a persisted Mongoid document into a Domain::Message" do
      created_at = Time.now.utc
      fake_document = double(
        "MessageDocument",
        id: double("BSON::ObjectId", to_s: "abc123"),
        to_number: "+14155550123",
        body: "hello",
        owner_id: "owner-1",
        status: "queued",
        external_sid: nil,
        created_at: created_at
      )
      allow(document_class).to receive(:create!).with(
        to_number: "+14155550123", body: "hello", owner_id: "owner-1",
        status: "queued", external_sid: nil
      ).and_return(fake_document)

      message = repository.create(base_attrs)

      expect(message).to be_a(Domain::Message)
      expect(message.id).to eq("abc123")
      expect(message.to_number).to eq("+14155550123")
      expect(message.status).to eq("queued")
      expect(message.created_at).to eq(created_at)
    end

    it "defaults status to queued when not provided in attrs (passed through to MessageDocument.create!)" do
      allow(document_class).to receive(:create!).with(hash_including(status: "queued"))
        .and_return(double("MessageDocument", id: double(to_s: "x"), to_number: "+14155550123",
                            body: "hello", owner_id: "owner-1", status: "queued",
                            external_sid: nil, created_at: Time.now.utc))

      repository.create(base_attrs)

      expect(document_class).to have_received(:create!).with(hash_including(status: "queued"))
    end

    it "translates a Mongo::Error into a RepositoryError instead of leaking the driver exception" do
      allow(document_class).to receive(:create!).and_raise(Mongo::Error, "connection refused")

      expect { repository.create(base_attrs) }.to raise_error(Repositories::RepositoryError, /temporarily unavailable/)
    end

    # Bug blitz (2026-07-15) follow-up: MessageDocument now has real
    # `validates` calls (previously had none). This should be UNREACHABLE
    # via the real call path (Services::SendMessageService validates first),
    # but proves the repository doesn't leak a raw Mongoid backtrace if a
    # future caller ever bypasses that.
    it "translates a Mongoid::Errors::Validation into a RepositoryError instead of leaking it raw" do
      allow(document_class).to receive(:create!).and_raise(Mongoid::Errors::Validation, "Body is too long")

      expect { repository.create(base_attrs) }.to raise_error(Repositories::RepositoryError, /temporarily unavailable/)
    end
  end

  describe "#find_for_owner" do
    it "queries scoped to owner_id, ordered newest-first, capped, and maps each result to a Domain::Message" do
      fake_document = double(
        "MessageDocument",
        id: double(to_s: "doc-1"),
        to_number: "+14155550123",
        body: "hi",
        owner_id: "owner-1",
        status: "sent",
        external_sid: "SID1",
        created_at: Time.now.utc
      )
      relation = double("Mongoid::Criteria")
      ordered_relation = double("Mongoid::Criteria (ordered)")
      capped_relation = [fake_document]
      allow(document_class).to receive(:where).with(owner_id: "owner-1").and_return(relation)
      allow(relation).to receive(:order).with(created_at: :desc).and_return(ordered_relation)
      # Bug blitz (2026-07-15) follow-up: find_for_owner now chains .limit
      # onto .order to cap unbounded growth per owner (see
      # Repositories::MessageRepositoryInterface::MAX_RESULTS_PER_OWNER).
      allow(ordered_relation).to receive(:limit)
        .with(Repositories::MessageRepositoryInterface::MAX_RESULTS_PER_OWNER)
        .and_return(capped_relation)

      results = repository.find_for_owner("owner-1")

      expect(results).to all(be_a(Domain::Message))
      expect(results.first.id).to eq("doc-1")
      expect(document_class).to have_received(:where).with(owner_id: "owner-1")
      expect(relation).to have_received(:order).with(created_at: :desc)
      expect(ordered_relation).to have_received(:limit)
        .with(Repositories::MessageRepositoryInterface::MAX_RESULTS_PER_OWNER)
    end

    it "returns an empty array when the owner has no messages" do
      relation = double("Mongoid::Criteria")
      ordered_relation = double("Mongoid::Criteria (ordered)")
      allow(document_class).to receive(:where).and_return(relation)
      allow(relation).to receive(:order).and_return(ordered_relation)
      allow(ordered_relation).to receive(:limit).and_return([])

      expect(repository.find_for_owner("owner-1")).to eq([])
    end

    it "translates a Mongo::Error into a RepositoryError instead of leaking the driver exception" do
      allow(document_class).to receive(:where).and_raise(Mongo::Error, "timeout")

      expect { repository.find_for_owner("owner-1") }.to raise_error(Repositories::RepositoryError, /temporarily unavailable/)
    end
  end

  # Bug blitz (2026-07-15) follow-up: this method had NO coverage at all in
  # this spec file (only in the Minitest InMemory suite and the RSpec shared
  # examples). Added here to match, including the new monotonicity guard.
  describe "#update_status_by_external_sid" do
    def fake_document_double(status:, id: "doc-1")
      double(
        "MessageDocument",
        id: double(to_s: id),
        to_number: "+14155550123",
        body: "hi",
        owner_id: "owner-1",
        status: status,
        external_sid: "SID1",
        created_at: Time.now.utc
      )
    end

    it "returns nil (a safe no-op) when no message matches the external_sid" do
      relation = double("Mongoid::Criteria")
      allow(document_class).to receive(:where).with(external_sid: "UNKNOWN").and_return(relation)
      allow(relation).to receive(:first).and_return(nil)

      expect(repository.update_status_by_external_sid("UNKNOWN", "delivered")).to be_nil
    end

    it "updates and returns the message on a genuinely forward status transition" do
      document = fake_document_double(status: "sent")
      relation = double("Mongoid::Criteria")
      allow(document_class).to receive(:where).with(external_sid: "SID1").and_return(relation)
      allow(relation).to receive(:first).and_return(document)
      allow(document).to receive(:update!).with(status: "delivered")
      # Simulates the mutation the real `update!` would perform on a plain
      # double: the repository reads `document.status` TWICE — once for the
      # regressive-status check (must still see the pre-update "sent"), and
      # once inside `to_domain` after the (stubbed) update (must see the
      # post-update "delivered"). `.and_return` with multiple args returns
      # each value in turn, then repeats the last for any further calls.
      allow(document).to receive(:status).and_return("sent", "delivered")

      result = repository.update_status_by_external_sid("SID1", "delivered")

      expect(document).to have_received(:update!).with(status: "delivered")
      expect(result.status).to eq("delivered")
    end

    # Bug blitz (2026-07-15) finding: a delayed/out-of-order callback must
    # not regress an already-more-advanced status backward.
    it "does not call update! and returns the message unchanged on a regressive status transition" do
      document = fake_document_double(status: "delivered")
      relation = double("Mongoid::Criteria")
      allow(document_class).to receive(:where).with(external_sid: "SID1").and_return(relation)
      allow(relation).to receive(:first).and_return(document)
      allow(document).to receive(:update!)

      result = repository.update_status_by_external_sid("SID1", "sent")

      expect(document).not_to have_received(:update!)
      expect(result.status).to eq("delivered")
    end

    it "translates a Mongo::Error into a RepositoryError instead of leaking the driver exception" do
      allow(document_class).to receive(:where).and_raise(Mongo::Error, "timeout")

      expect { repository.update_status_by_external_sid("SID1", "delivered") }
        .to raise_error(Repositories::RepositoryError, /temporarily unavailable/)
    end

    it "translates a Mongoid::Errors::Validation into a RepositoryError instead of leaking it raw" do
      document = fake_document_double(status: "sent")
      relation = double("Mongoid::Criteria")
      allow(document_class).to receive(:where).with(external_sid: "SID1").and_return(relation)
      allow(relation).to receive(:first).and_return(document)
      allow(document).to receive(:update!).and_raise(Mongoid::Errors::Validation, "invalid")

      expect { repository.update_status_by_external_sid("SID1", "delivered") }
        .to raise_error(Repositories::RepositoryError, /temporarily unavailable/)
    end
  end
end

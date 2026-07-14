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
  end

  describe "#find_for_owner" do
    it "queries scoped to owner_id, ordered newest-first, and maps each result to a Domain::Message" do
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
      ordered_relation = [fake_document]
      allow(document_class).to receive(:where).with(owner_id: "owner-1").and_return(relation)
      allow(relation).to receive(:order).with(created_at: :desc).and_return(ordered_relation)

      results = repository.find_for_owner("owner-1")

      expect(results).to all(be_a(Domain::Message))
      expect(results.first.id).to eq("doc-1")
      expect(document_class).to have_received(:where).with(owner_id: "owner-1")
      expect(relation).to have_received(:order).with(created_at: :desc)
    end

    it "returns an empty array when the owner has no messages" do
      relation = double("Mongoid::Criteria")
      allow(document_class).to receive(:where).and_return(relation)
      allow(relation).to receive(:order).and_return([])

      expect(repository.find_for_owner("owner-1")).to eq([])
    end

    it "translates a Mongo::Error into a RepositoryError instead of leaking the driver exception" do
      allow(document_class).to receive(:where).and_raise(Mongo::Error, "timeout")

      expect { repository.find_for_owner("owner-1") }.to raise_error(Repositories::RepositoryError, /temporarily unavailable/)
    end
  end
end

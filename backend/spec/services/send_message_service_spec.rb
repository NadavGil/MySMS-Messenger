# Plain-Ruby spec: no Rails boot, no Mongo/Twilio required (tech-design.md
# §7 — "Service specs — inject fakes directly ..."). Closes MAJ3 from
# doc/code-review-iteration-1.md, and regression-tests the MAJ1/MAJ2 fix
# (non-string to_number/body must be rejected with a 422-shaped error, not
# raise or silently bypass validation).
#
# Run with: bundle exec rspec spec/services/send_message_service_spec.rb
# (NOTE: bundler/rspec could not be installed in the sandbox used to author
# this spec — it was smoke-tested with a disposable plain-Ruby script that
# exercises the same class/method calls without the RSpec DSL. See the
# code-review fix-up report for details.)
require "spec_helper"
require_relative "../../app/domain/message"
require_relative "../../app/repositories/message_repository_interface"
require_relative "../../app/repositories/in_memory_message_repository"
require_relative "../../app/gateways/sms_gateway_interface"
require_relative "../../app/services/send_message_service"

RSpec.describe Services::SendMessageService do
  # Fake gateway (dependency-injected), lets each example control the
  # success/failure outcome explicitly rather than relying on
  # FakeSmsGateway's magic failure number.
  class ScriptedFakeGateway
    include Gateways::SmsGatewayInterface

    def initialize(success:, external_sid: "SM123", error: nil)
      @success = success
      @external_sid = external_sid
      @error = error
    end

    def send_sms(to:, body:)
      Gateways::SmsGatewayInterface::Result.new(
        success: @success, external_sid: @success ? @external_sid : nil, error: @error
      )
    end
  end

  let(:repository) { Repositories::InMemoryMessageRepository.new }
  let(:owner_id) { "owner-1" }

  subject(:service) { described_class.new(repository: repository, gateway: gateway) }

  context "valid send" do
    let(:gateway) { ScriptedFakeGateway.new(success: true, external_sid: "SM999") }

    it "persists the message with status sent and the gateway's external_sid" do
      result = service.call(to_number: "+14155550123", body: "hello", owner_id: owner_id)

      expect(result.ok?).to eq(true)
      expect(result.errors).to be_nil
      expect(result.message.status).to eq("sent")
      expect(result.message.external_sid).to eq("SM999")
      expect(result.message.to_number).to eq("+14155550123")
      expect(result.message.body).to eq("hello")
      expect(result.message.owner_id).to eq(owner_id)
    end

    it "actually persists into the injected repository" do
      service.call(to_number: "+14155550123", body: "hello", owner_id: owner_id)

      expect(repository.find_for_owner(owner_id).size).to eq(1)
    end
  end

  context "gateway failure path" do
    let(:gateway) { ScriptedFakeGateway.new(success: false, error: "provider rejected") }

    it "still persists the message, with status failed and no external_sid" do
      result = service.call(to_number: "+14155550123", body: "hello", owner_id: owner_id)

      expect(result.ok?).to eq(true)
      expect(result.message.status).to eq("failed")
      expect(result.message.external_sid).to be_nil
      expect(repository.find_for_owner(owner_id).first.status).to eq("failed")
    end
  end

  context "invalid to_number" do
    let(:gateway) { ScriptedFakeGateway.new(success: true) }

    it "rejects a missing (nil) to_number without touching the gateway/repository" do
      result = service.call(to_number: nil, body: "hello", owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:to_number]).to eq(["is required"])
      expect(repository.find_for_owner(owner_id)).to eq([])
    end

    it "rejects a blank to_number" do
      result = service.call(to_number: "   ", body: "hello", owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:to_number]).to eq(["is required"])
    end

    it "rejects a malformed (non-E164) to_number" do
      result = service.call(to_number: "0123456", body: "hello", owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:to_number]).to eq(["is not a valid E.164 number"])
    end

    it "rejects a non-string to_number (e.g. Hash from a nested param) with a 422-shaped error, not a raise (MAJ1 regression)" do
      expect {
        result = service.call(to_number: { "a" => "1" }, body: "hello", owner_id: owner_id)
        expect(result.ok?).to eq(false)
        expect(result.errors[:to_number]).to eq(["must be a string"])
      }.not_to raise_error
    end

    it "rejects an Array to_number the same way" do
      result = service.call(to_number: ["+14155550123"], body: "hello", owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:to_number]).to eq(["must be a string"])
    end
  end

  context "invalid body" do
    let(:gateway) { ScriptedFakeGateway.new(success: true) }

    it "rejects a blank body" do
      result = service.call(to_number: "+14155550123", body: "", owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:body]).to eq(["is required"])
    end

    it "rejects a body over 250 characters" do
      result = service.call(to_number: "+14155550123", body: "a" * 251, owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:body]).to eq(["must be 250 characters or fewer"])
    end

    it "accepts a body of exactly 250 characters" do
      result = service.call(to_number: "+14155550123", body: "a" * 250, owner_id: owner_id)

      expect(result.ok?).to eq(true)
    end

    it "rejects a non-string (Hash) body with a 422-shaped error rather than bypassing the length check (MAJ2 regression)" do
      result = service.call(to_number: "+14155550123", body: { "x" => "1" }, owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:body]).to eq(["must be a string"])
      expect(repository.find_for_owner(owner_id)).to eq([])
    end

    it "rejects a non-string (Array) body that would otherwise have a small #length and sail past the 250 check" do
      # An Array's #length ("number of elements") could be tiny even if the
      # underlying content is huge/malformed — must be rejected on type
      # alone, never on the coincidental length of the wrong type.
      result = service.call(to_number: "+14155550123", body: ["x"], owner_id: owner_id)

      expect(result.ok?).to eq(false)
      expect(result.errors[:body]).to eq(["must be a string"])
    end
  end

  context "both invalid" do
    let(:gateway) { ScriptedFakeGateway.new(success: true) }

    it "returns errors for both fields and never calls the gateway/repository" do
      result = service.call(to_number: "", body: "", owner_id: owner_id)

      expect(result.errors.keys).to contain_exactly(:to_number, :body)
      expect(repository.find_for_owner(owner_id)).to eq([])
    end
  end
end

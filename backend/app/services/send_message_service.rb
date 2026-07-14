module Services
  # Use-case: validate, send via gateway, persist regardless of outcome
  # (tech-design.md §5, §0 "Persist-on-send-failure": persist always).
  # Constructor-injected collaborators (repository, gateway) so this is
  # unit-testable with fakes - no Rails/Mongo/network required.
  class SendMessageService
    Result = Struct.new(:ok, :message, :errors, keyword_init: true) do
      def ok?
        ok
      end
    end

    E164_PATTERN = /\A\+[1-9]\d{1,14}\z/
    MAX_BODY_LENGTH = 250

    def initialize(repository:, gateway:)
      @repository = repository
      @gateway = gateway
    end

    def call(to_number:, body:, owner_id:)
      errors = validate(to_number: to_number, body: body)
      return Result.new(ok: false, message: nil, errors: errors) if errors.any?

      gateway_result = @gateway.send_sms(to: to_number, body: body)
      status = gateway_result.success ? "sent" : "failed"

      message = @repository.create(
        to_number: to_number,
        body: body,
        owner_id: owner_id,
        status: status,
        external_sid: gateway_result.external_sid
      )

      Result.new(ok: true, message: message, errors: nil)
    end

    private

    def validate(to_number:, body:)
      errors = {}

      # MAJ1/MAJ2 fix: a client can send a nested param (e.g. `to_number[a]=1`)
      # which Rails parses as a Hash/ActionController::Parameters, not a
      # String. Reject any non-String, non-nil value explicitly *before* any
      # regex/length check runs, so `Regexp#match?`/`#length` never see a
      # non-String and every subsequent check operates on a real String —
      # closing both the TypeError-raising path (MAJ1) and the
      # length-check-bypass path (MAJ2) with the same structured 422 error
      # shape as any other invalid input, rather than a bare 500 or a
      # silent Mongoid coercion.
      if !to_number.nil? && !to_number.is_a?(String)
        errors[:to_number] = ["must be a string"]
      elsif to_number.to_s.strip.empty?
        errors[:to_number] = ["is required"]
      elsif !E164_PATTERN.match?(to_number.to_s)
        errors[:to_number] = ["is not a valid E.164 number"]
      end

      if !body.nil? && !body.is_a?(String)
        errors[:body] = ["must be a string"]
      elsif body.to_s.empty?
        errors[:body] = ["is required"]
      elsif body.to_s.length > MAX_BODY_LENGTH
        errors[:body] = ["must be #{MAX_BODY_LENGTH} characters or fewer"]
      end

      errors
    end
  end
end

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

      if to_number.to_s.strip.empty?
        errors[:to_number] = ["is required"]
      elsif !E164_PATTERN.match?(to_number)
        errors[:to_number] = ["is not a valid E.164 number"]
      end

      if body.to_s.empty?
        errors[:body] = ["is required"]
      elsif body.length > MAX_BODY_LENGTH
        errors[:body] = ["must be #{MAX_BODY_LENGTH} characters or fewer"]
      end

      errors
    end
  end
end

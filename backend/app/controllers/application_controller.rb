class ApplicationController < ActionController::API
  include CurrentIdentity

  # qa-report-round1.md N3: a Mongo outage/driver error is repackaged by
  # MongoMessageRepository into Repositories::RepositoryError; surface it as
  # a structured 5xx matching the API's existing `{ errors: {...} }` shape
  # instead of an unhandled-exception 500 with a raw backtrace.
  #
  # Passed as a STRING, not a bare constant reference: referencing
  # `Repositories::RepositoryError` directly here forces Ruby to resolve it
  # the moment this class body loads, which can race Zeitwerk's autoloading
  # of the `Repositories` namespace and raise a boot-time
  # `NameError: uninitialized constant ApplicationController::Repositories`
  # (hit on first real Rails boot outside the sandbox, where gems could
  # finally install for real). `rescue_from` resolves a String lazily, only
  # when an actual exception needs matching, sidestepping the ordering
  # issue entirely.
  rescue_from "Repositories::RepositoryError" do |error|
    render json: { errors: { base: [error.message] } }, status: :service_unavailable
  end
end

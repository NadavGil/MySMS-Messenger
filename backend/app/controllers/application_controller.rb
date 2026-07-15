class ApplicationController < ActionController::API
  # ActionController::API deliberately omits the `cookies` helper (it's part
  # of the full ActionController::Base stack, not the lightweight API-only
  # one). config/application.rb already adds the ActionDispatch::Cookies
  # *middleware* so signed cookies are parsed off the request, but the
  # controller-level `cookies`/`cookies.signed` accessor CurrentIdentity
  # calls also needs this module included explicitly, or every request
  # blows up with `NameError: undefined local variable or method 'cookies'`
  # (hit on the director's first real run - never surfaced in the sandbox
  # since Rails could never boot there at all).
  include ActionController::Cookies
  include CurrentIdentity

  # REFACTOR (post-live-run audit): ActionController::API enables
  # ParamsWrapper by default, which duplicates every JSON body under a
  # controller-derived key (e.g. POST /api/v1/messages with
  # {"to_number":...,"body":...} also arrives wrapped as
  # params[:message] = {"to_number":...,"body":...}). Harmless — the
  # top-level params SendMessageService reads are unaffected — but it's
  # log/param noise with no purpose in a flat, non-resource-form JSON API
  # that never reads the wrapped key. Disabled globally rather than per
  # controller.
  wrap_parameters false

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

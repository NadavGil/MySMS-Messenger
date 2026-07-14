class ApplicationController < ActionController::API
  include CurrentIdentity

  # qa-report-round1.md N3: a Mongo outage/driver error is repackaged by
  # MongoMessageRepository into Repositories::RepositoryError; surface it as
  # a structured 5xx matching the API's existing `{ errors: {...} }` shape
  # instead of an unhandled-exception 500 with a raw backtrace.
  rescue_from Repositories::RepositoryError do |error|
    render json: { errors: { base: [error.message] } }, status: :service_unavailable
  end
end

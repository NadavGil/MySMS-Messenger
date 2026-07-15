require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.action_controller.perform_caching = true

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [:request_id]

  config.active_support.report_deprecations = false

  config.force_ssl = true

  # tech-design.md §14.6 (the force_ssl/health-check finding):
  # silence_healthcheck_path below only silences the request LOG line for
  # /health - it does NOT exempt /health from the force_ssl redirect. Fly's
  # internal http_service health check hits the machine over plain HTTP and
  # may not carry X-Forwarded-Proto: https, so without this exclude Rails
  # 301-redirects the check to https:// and Fly sees a failing check (301,
  # not 200) even though the app is healthy - the auth skip on
  # HealthController does not help, since this redirect happens in
  # middleware before the controller runs. This keeps HSTS + the redirect
  # for every other path; only /health is exempted.
  config.ssl_options = {
    redirect: { exclude: ->(request) { request.path == "/health" } }
  }

  config.silence_healthcheck_path = "/health"

  # security-review-round1.md M4 / fix item 7: no config/master.key or
  # config/credentials.yml.enc is committed to this repo (verified - none
  # exist), so Rails has no committed secret to derive secret_key_base from
  # in production. Require it explicitly from ENV instead of silently
  # falling back to an uninitialized/missing credentials store - this fails
  # loudly at boot if SECRET_KEY_BASE is not set, rather than booting with a
  # key nobody generated/rotated/tracked. CurrentIdentity's signed cookie
  # (cookies.signed) depends directly on this value.
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
end

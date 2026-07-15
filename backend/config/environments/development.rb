require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true

  config.action_controller.perform_caching = false

  config.active_support.deprecation = :log

  config.log_level = :debug

  config.i18n.raise_on_missing_translations = true

  # No config/master.key or credentials.yml.enc is committed to this repo
  # (tech-design.md §11, HLD §7.3 - secrets are never committed), so Rails
  # has no default secret source in this or any environment. Production
  # requires SECRET_KEY_BASE from ENV with no fallback (see
  # config/environments/production.rb); for local dev, allow the same ENV
  # var but fall back to a fixed, clearly-labeled insecure value so the app
  # boots out of the box without every contributor generating credentials
  # first. Never used in production - that path has no fallback at all.
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "insecure-development-only-secret-key-base-do-not-use-in-production")
end

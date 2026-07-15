require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?

  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  config.action_dispatch.show_exceptions = :rescuable

  config.action_controller.raise_on_missing_callback_actions = true

  config.log_level = :warn

  # NOTE: repository/gateway wiring is NOT set here. It is resolved once,
  # for every environment, by config/initializers/container.rb (CP3) so
  # there is a single source of truth for the IoC defaults
  # (test defaults to in_memory/fake — see tech-design.md §2.6).

  # Same rationale as config/environments/development.rb: no credentials
  # file is committed, so test needs its own fallback secret too.
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "insecure-test-only-secret-key-base-do-not-use-in-production")
end

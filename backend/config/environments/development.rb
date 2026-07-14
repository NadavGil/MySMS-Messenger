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
end

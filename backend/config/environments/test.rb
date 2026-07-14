require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?

  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  config.action_dispatch.show_exceptions = :rescuable

  config.action_controller.raise_on_missing_callback_actions = true

  config.log_level = :warn

  # Test defaults (tech-design.md §2.6 / §7): fast, no external deps.
  config.x.message_repository_class = "Repositories::InMemoryMessageRepository"
  config.x.sms_gateway_class = "Gateways::FakeSmsGateway"
end

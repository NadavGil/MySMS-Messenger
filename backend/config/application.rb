require_relative "boot"

require "rails"
# Only the frameworks actually needed for an API-only, Mongoid-backed app.
# (--skip-active-record: no ActiveRecord::Railtie / no ActionView/Sprockets/etc.)
require "active_model/railtie"
require "active_job/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module MysmsMessenger
  class Application < Rails::Application
    config.load_defaults 7.1

    # API-only mode: skip view/flash/cookie-session middleware Rails would
    # otherwise add for a browser app. We re-add just the cookies middleware
    # below because CurrentIdentity (CP5) needs signed cookies.
    config.api_only = true

    # Autoload app/domain, app/repositories, app/gateways, app/services as
    # Domain::, Repositories::, Gateways::, Services:: respectively. This is
    # automatic under Zeitwerk (folder name -> module name) — no extra config
    # needed (see tech-design.md §2.4).

    # Signed cookies (for CurrentIdentity, CP5) require the cookies middleware
    # even in API-only mode.
    config.middleware.use ActionDispatch::Cookies

    # Rate limiting (security-review-round1.md H1) -
    # config/initializers/rack_attack.rb defines the actual throttle rules;
    # this wires the middleware into the stack (API-only mode does not add
    # it automatically the way a full Rails app would).
    config.middleware.use Rack::Attack

    # Namespace for config-driven wiring resolved in
    # config/initializers/container.rb (CP3).
    config.x.message_repository_class = nil
    config.x.sms_gateway_class = nil
  end
end

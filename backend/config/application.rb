require_relative "boot"

require "rails"
# Only the frameworks actually needed for an API-only, Mongoid-backed app.
# (--skip-active-record: no ActiveRecord::Railtie / no ActionView/Sprockets/etc.)
require "active_model/railtie"
require "active_job/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

# CORRECTION to a wrong assumption baked into this codebase from the start
# (tech-design.md §2.4 originally claimed this was automatic - it is not,
# confirmed only once Rails could actually boot for real outside the
# sandbox that built this app): Rails adds every direct subdirectory of
# app/ as its own Zeitwerk autoload ROOT mapped to the TOP-LEVEL namespace
# by default - e.g. app/models/foo.rb => ::Foo, app/services/foo.rb =>
# ::Foo too, NOT Services::Foo. Namespacing a custom app/* directory by its
# folder name (Domain::, Repositories::, Gateways::, Services:: - used
# throughout this codebase, including the Minitest suite under
# backend/test/) requires explicitly telling Zeitwerk. These four bare
# modules must exist as real constants before `push_dir(..., namespace:)`
# can reference them.
module Domain; end
module Repositories; end
module Gateways; end
module Services; end

module MysmsMessenger
  class Application < Rails::Application
    config.load_defaults 7.1

    # API-only mode: skip view/flash/cookie-session middleware Rails would
    # otherwise add for a browser app. We re-add just the cookies middleware
    # below because CurrentIdentity (CP5) needs signed cookies.
    config.api_only = true

    # Remove Rails' default (unnamespaced) autoload roots for these four
    # directories, then re-register each explicitly with its intended
    # namespace, so e.g. app/services/container.rb correctly autoloads as
    # Services::Container (matching every reference in this codebase)
    # instead of a bare top-level Container that nothing ever asks for.
    %w[domain repositories gateways services].each do |dir|
      full_path = config.root.join("app", dir).to_s
      config.autoload_paths.delete(full_path)
      config.eager_load_paths.delete(full_path)
    end

    config.before_initialize do
      Rails.autoloaders.main.push_dir(config.root.join("app/domain"), namespace: Domain)
      Rails.autoloaders.main.push_dir(config.root.join("app/repositories"), namespace: Repositories)
      Rails.autoloaders.main.push_dir(config.root.join("app/gateways"), namespace: Gateways)
      Rails.autoloaders.main.push_dir(config.root.join("app/services"), namespace: Services)
    end

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

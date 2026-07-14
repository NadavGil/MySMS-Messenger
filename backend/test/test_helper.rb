# Bootstrap for the Minitest suite under backend/test/.
#
# Deliberately does NOT touch Rails/Bundler/Mongoid — this sandbox has no
# network access to rubygems.org, so none of those gems can ever be
# installed here. This file only requires Ruby stdlib plus the handful of
# framework-independent app classes that have zero gem dependencies, so the
# whole suite runs today with a bare `ruby` invocation.
require "minitest/autorun"
require "logger"

APP_ROOT = File.expand_path("../../app", __FILE__)
$LOAD_PATH.unshift(APP_ROOT) unless $LOAD_PATH.include?(APP_ROOT)

# FakeSmsGateway calls Rails.logger.info(...) (it's meant to run inside a
# Rails process normally). Outside Rails, stub just enough of the constant
# so that call doesn't blow up. Guarded so this is a no-op if a real Rails
# constant is ever loaded first (it never is in this suite, but this keeps
# the stub honest/safe to require anywhere).
unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(IO::NULL)
    end
  end
end

# Dependency order: interfaces/domain before implementations that include
# or reference them.
require_relative "../app/domain/message"
require_relative "../app/repositories/message_repository_interface"
require_relative "../app/repositories/in_memory_message_repository"
require_relative "../app/services/send_message_service"
require_relative "../app/services/list_messages_service"
require_relative "../app/gateways/sms_gateway_interface"
require_relative "../app/gateways/fake_sms_gateway"

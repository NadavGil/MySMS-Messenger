# Turns the class-name strings resolved by config/initializers/container.rb
# into wired instances, so controllers stay one-liners (tech-design.md §2.6).
#
#   Services::Container.message_repository  #=> Repositories::MongoMessageRepository.new (or in_memory)
#   Services::Container.sms_gateway         #=> Gateways::TwilioSmsGateway.new (or fake)
#   Services::Container.send_message_service
#   Services::Container.list_messages_service
#
# DEVIATION FROM tech-design.md §2.6: the doc names this module bare
# `Container` living in app/services/container.rb. Under Zeitwerk, an
# autoload root's file naming must match its namespace, so app/services/*
# is expected to define Services::*; a bare top-level `Container` defined
# there would raise a Zeitwerk::NameError at boot. Namespacing it as
# Services::Container keeps the same file location and behavior while
# actually booting. Flagged for Tech Lead/Nadav sign-off — CP6/CP7
# controllers should call `Services::Container.send_message_service` /
# `Services::Container.list_messages_service`.
#
# NOTE: Services::SendMessageService / Services::ListMessagesService are
# introduced at CP6/CP7. Their factory methods below are safe to define now
# (Ruby only resolves the constant when the method is actually called).
module Services
  module Container
    module_function

    def message_repository
      Rails.configuration.x.message_repository_class.constantize.new
    end

    def sms_gateway
      Rails.configuration.x.sms_gateway_class.constantize.new
    end

    def send_message_service
      SendMessageService.new(repository: message_repository, gateway: sms_gateway)
    end

    def list_messages_service
      ListMessagesService.new(repository: message_repository)
    end
  end
end

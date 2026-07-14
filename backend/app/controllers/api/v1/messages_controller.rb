module Api
  module V1
    # Thin controller (tech-design.md §2.8): delegates to
    # Services::Container-wired use-cases; no persistence/gateway logic here.
    class MessagesController < ApplicationController
      # POST /api/v1/messages
      def create
        result = Services::Container.send_message_service.call(
          to_number: params[:to_number],
          body: params[:body],
          owner_id: current_identity
        )

        if result.ok?
          render json: serialize(result.message), status: :created
        else
          render json: { errors: result.errors }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/messages
      # Newest-first, scoped ONLY to the current CurrentIdentity owner_id
      # (tech-design.md §6.2 / HLD §5 scoping requirement). `count` feeds the
      # wireframe's "Message History (N)" header.
      def index
        messages = Services::Container.list_messages_service.call(owner_id: current_identity)
        render json: { count: messages.size, messages: messages.map { |m| serialize(m) } }
      end

      private

      def serialize(message)
        {
          id: message.id,
          to_number: message.to_number,
          body: message.body,
          status: message.status,
          external_sid: message.external_sid,
          created_at: message.created_at.iso8601
        }
      end
    end
  end
end

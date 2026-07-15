module Api
  module V1
    class HealthController < ApplicationController
      # Health checks must work with no auth cookie at all (load balancers /
      # uptime monitors never log in). Bonus 1 made CurrentIdentity's
      # before_action auth-required by default (see current_identity.rb),
      # so this controller must explicitly opt out (mirrors
      # AuthController's signup/login/logout skip) - see
      # qa-security-review-bonus1-auth.md C1/B1.
      skip_before_action :resolve_current_identity

      # GET /health
      def show
        render json: { status: "ok" }, status: :ok
      end
    end
  end
end

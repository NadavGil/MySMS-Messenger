module Api
  module V1
    # Bonus 1 authentication (tech-design.md §13.4). Inherits
    # ApplicationController so it gets ActionController::Cookies,
    # wrap_parameters false, rescue_from RepositoryError, and CurrentIdentity.
    class AuthController < ApplicationController
      # signup/login run BEFORE auth exists; logout is idempotent (never 401).
      # `me` intentionally does NOT skip — the before_action's 401 IS its
      # "not logged in" answer.
      skip_before_action :resolve_current_identity, only: %i[signup login logout]

      # POST /api/v1/auth/signup
      def signup
        user = User.new(username: params[:username], password: params[:password])
        if user.save
          sign_in(user)
          render json: user_json(user), status: :created
        else
          render json: { errors: user.errors.messages }, status: :unprocessable_entity
        end
      rescue Mongo::Error => e
        # Bug blitz (2026-07-15) finding: User#username uniqueness is
        # deliberately app-level-validated-but-DB-index-authoritative (see
        # user.rb's "racy; index is authoritative" comment) — two concurrent
        # signups for the same normalized username can BOTH pass the
        # Mongoid uniqueness check and race to `save`, with the loser
        # hitting the unique index at the driver level instead. Unlike
        # MongoMessageRepository (which already wraps every Mongo call and
        # re-raises as Repositories::RepositoryError, caught globally in
        # ApplicationController), User is a plain Mongoid model with no
        # repository wrapper, so this raw Mongo::Error was previously
        # unhandled here — an unhandled 500 with a driver backtrace instead
        # of the same structured 422 a normal "username taken" gets.
        # Duplicate-key (E11000) is by far the only realistic case (the
        # unique index is on username, and nothing else in this codepath can
        # legitimately fail this way), so it's safe to answer with the same
        # response a synchronous uniqueness-validation failure would give.
        render json: { errors: { username: ["has already been taken"] } },
               status: :unprocessable_entity
      end

      # POST /api/v1/auth/login
      def login
        user = User.where(username: params[:username].to_s.downcase.strip).first
        # qa-security-review-bonus1-auth.md M1: `user&.authenticate` alone
        # short-circuits on a nil user, skipping the bcrypt compare entirely,
        # which makes a nonexistent-username request measurably faster than
        # a wrong-password one against a real username (bcrypt ~50-250ms vs.
        # a sub-millisecond DB miss) - a timing side-channel for username
        # enumeration. Run a dummy bcrypt compare on the miss path so both
        # branches pay the same bcrypt cost. DUMMY_PASSWORD_DIGEST is a
        # fixed, valid bcrypt hash (not tied to any real account) purely to
        # burn equivalent CPU time; its plaintext is never used/checked.
        if user
          authenticated = user.authenticate(params[:password].to_s)
        else
          BCrypt::Password.new(DUMMY_PASSWORD_DIGEST) == params[:password].to_s
          authenticated = false
        end

        if authenticated
          sign_in(user)
          render json: user_json(user), status: :ok
        else
          render json: { errors: { base: ["Invalid username or password"] } },
                 status: :unauthorized
        end
      end

      # DELETE /api/v1/auth/logout
      def logout
        sign_out
        head :no_content
      end

      # GET /api/v1/auth/me  (before_action already 401s if unauthenticated)
      def me
        render json: user_json(current_user), status: :ok
      end

      private

      # Precomputed once at class-load; the plaintext behind this hash is
      # unknown/irrelevant - it exists solely to give the miss path a bcrypt
      # compare of equivalent cost (M1 timing-enumeration mitigation).
      DUMMY_PASSWORD_DIGEST = BCrypt::Password.create("dummy-password-for-timing-parity").to_s

      # NEVER expose password_digest.
      def user_json(user) = { id: user.id.to_s, username: user.username }
    end
  end
end

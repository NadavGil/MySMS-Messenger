Rails.application.routes.draw do
  get "/health", to: "api/v1/health#show"

  namespace :api do
    namespace :v1 do
      # messages_controller is wired up at CP6/CP7; declaring the route now
      # matches the locked §6 API contract and does not require the
      # controller to exist until a request actually hits it.
      resources :messages, only: [:create, :index]

      # Bonus 1 authentication (tech-design.md §13.5).
      post   "auth/signup", to: "auth#signup"
      post   "auth/login",  to: "auth#login"
      delete "auth/logout", to: "auth#logout"
      get    "auth/me",     to: "auth#me"

      # Bonus 3: Twilio delivery-status webhook (tech-design.md §15.2).
      # Server-to-server integration surface, not part of the SPA API
      # contract - authenticated by Twilio request signature, not the
      # :msms_owner cookie.
      namespace :webhooks do
        post "twilio/status", to: "twilio_status#create"
      end
    end
  end
end

Rails.application.routes.draw do
  get "/health", to: "api/v1/health#show"

  namespace :api do
    namespace :v1 do
      # messages_controller is wired up at CP6/CP7; declaring the route now
      # matches the locked §6 API contract and does not require the
      # controller to exist until a request actually hits it.
      resources :messages, only: [:create, :index]
    end
  end
end

require "sidekiq/web"
require "sidekiq-scheduler/web"

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Temporary Sentry verification route — remove after confirming capture.
  get "/debug-sentry", to: "sentry_debug#show" if Rails.env.development?

  root "home#show"
  get "/map", to: "maps#show", as: :map
  get "/alerts", to: "alerts#show", as: :alerts

  get "/sitemap.xml", to: "sitemaps#index", as: :sitemap
  get "/sitemaps/static.xml", to: "sitemaps#static", as: :sitemap_static
  get "/sitemaps/:state.xml", to: "sitemaps#state", as: :sitemap_state,
      constraints: { state: /[a-z]{2}/ }

  get "/og.png", to: "og_images#default", as: :og_default
  get "/og/gauges/:site_number.png", to: "og_images#station", as: :og_station,
      constraints: { site_number: /\d+/ }

  get "/gauges/:state", to: "states#show", as: :state_gauges, constraints: { state: /[a-z]{2}/ }
  get "/gauges/:state/:site_number_slug", to: "gauges#show", as: :gauge,
      constraints: { state: /[a-z]{2}/, site_number_slug: /\d+.+/ }
  get "/gauges/:site_number", to: "gauges#show", as: :gauge_short, constraints: { site_number: /\d+/ }

  get "/pages/:id", to: "pages#show", as: :page
  %w[about disclosures faq privacy terms].each do |page|
    get "/#{page}", to: "pages#show", id: page, as: page
  end

  get "/contact", to: "pages#show", id: "contact", as: :contact
  post "/contact", to: "contacts#create"

  resource :temperature_unit, only: :update

  namespace :api do
    namespace :map do
      resources :stations, only: :index do
        get :search, on: :collection
        get :nearest, on: :collection
      end
    end
    resources :gauges, only: [] do
      resources :observations, only: :index, module: :gauges
    end
  end

  mount Sidekiq::Web => "/sidekiq" if Rails.env.development?
end

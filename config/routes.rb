require "sidekiq/web"
require "sidekiq-scheduler/web"

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "/.well-known/api-catalog", to: "well_known/api_catalog#show", as: :api_catalog

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

  get "/subscriptions", to: "subscriptions#new", as: :subscriptions
  post "/subscriptions", to: "subscriptions#create"
  get "/subscriptions/verify/:token", to: "subscriptions/verifications#show", as: :subscriptions_verify
  get "/subscriptions/manage/:token", to: "subscriptions/manages#show", as: :subscriptions_manage
  patch "/subscriptions/manage/:token", to: "subscriptions/manages#update"
  delete "/subscriptions/manage/:token/watches/:id", to: "subscriptions/manages#destroy_watch", as: :subscriptions_manage_watch
  post "/subscriptions/manage/:token/pause", to: "subscriptions/manages#pause", as: :subscriptions_manage_pause
  post "/subscriptions/manage/:token/unpause", to: "subscriptions/manages#unpause", as: :subscriptions_manage_unpause
  get "/subscriptions/unsubscribe/:token", to: "subscriptions/unsubscribes#show", as: :subscriptions_unsubscribe
  post "/subscriptions/unsubscribe/:token", to: "subscriptions/unsubscribes#create"

  resource :temperature_unit, only: :update

  get "/admin", to: "admin/dashboard#show", as: :admin
  get "/admin/sections/:section", to: "admin/dashboard#section", as: :admin_dashboard_section,
      constraints: { section: /core|pipeline|growth|jobs|states|health/ }
  get "/admin/stations", to: "admin/stations#index", as: :admin_stations
  get "/admin/stations/:site_number", to: "admin/stations#show", as: :admin_station,
      constraints: { site_number: /\d+/ }
  get "/admin/settings", to: "admin/settings#show", as: :admin_settings
  patch "/admin/settings", to: "admin/settings#update"
  delete "/admin/settings/:key", to: "admin/settings#reset", as: :reset_admin_settings
  post "/admin/maintenance/:key", to: "admin/maintenance#create", as: :admin_maintenance
  get "/admin/login", to: "admin/sessions#new", as: :admin_login
  post "/admin/login", to: "admin/sessions#create"
  delete "/admin/logout", to: "admin/sessions#destroy", as: :admin_logout

  # Session gate (same login as /admin). Unset DASHBOARD_PW → 404 inside the gate.
  # Attach once; reloads must not stack duplicates.
  unless Sidekiq::Web.middlewares.any? { |(args, _block)| args.first == Admin::SidekiqSessionGate }
    Sidekiq::Web.use Admin::SidekiqSessionGate
  end
  mount Sidekiq::Web => "/admin/sidekiq"

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
end

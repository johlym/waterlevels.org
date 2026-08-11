# Register admin settings after autoloading so definitions reload in development.
Rails.application.config.to_prepare do
  Admin::Settings::Catalog.register!
end

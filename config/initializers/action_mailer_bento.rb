# Tests keep :test. Production always uses Bento. Development uses Bento when keys are set.
Rails.application.configure do
  next if Rails.env.test?

  keys_present = ENV["BENTO_SITE_UUID"].present? &&
                 ENV["BENTO_PUBLISHABLE_KEY"].present? &&
                 ENV["BENTO_SECRET_KEY"].present?

  if Rails.env.production? || keys_present
    config.action_mailer.delivery_method = :bento_actionmailer
    config.action_mailer.bento_actionmailer_settings = {
      site_uuid: ENV["BENTO_SITE_UUID"],
      publishable_key: ENV["BENTO_PUBLISHABLE_KEY"],
      secret_key: ENV["BENTO_SECRET_KEY"]
    }
  end
end

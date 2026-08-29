web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq -C config/sidekiq.yml
sync_worker: bundle exec sidekiq -C config/sidekiq_sync.yml
iv_repair_worker: bundle exec sidekiq -C config/sidekiq_iv_repair.yml
iv_repair_scar_worker: bundle exec sidekiq -C config/sidekiq_iv_repair_scar.yml
historical_worker: bundle exec sidekiq -C config/sidekiq_historical.yml
notifications_worker: bundle exec sidekiq -C config/sidekiq_notifications.yml
release: bundle exec rails db:migrate

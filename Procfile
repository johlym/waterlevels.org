web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq -C config/sidekiq.yml
sync_worker: bundle exec sidekiq -C config/sidekiq_sync.yml
iv_repair_worker: bundle exec sidekiq -C config/sidekiq_iv_repair.yml
historical_worker: bundle exec sidekiq -C config/sidekiq_historical.yml
release: bundle exec rails db:migrate

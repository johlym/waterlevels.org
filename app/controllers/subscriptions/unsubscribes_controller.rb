# frozen_string_literal: true

module Subscriptions
  class UnsubscribesController < BaseController
    before_action :load_token!

    # One-click email links land here (GET) with a confirm form that POSTs.
    def show
      @scope = params[:scope].presence || "all"
      @watch = find_watch if @scope == "watch"
    end

    def create
      @scope = params[:scope].presence || "all"

      case @scope
      when "watch"
        watch = find_watch
        if watch
          watch.alert_rules.update_all(enabled: false, updated_at: Time.current)
          watch.destroy!
          @token.mark_used!
          redirect_to subscriptions_path, notice: "Unsubscribed from that station."
        else
          redirect_to subscriptions_path, alert: "That station watch was not found."
        end
      else
        @subscriber.unsubscribe_all!
        @token.mark_used!
        redirect_to subscriptions_path, notice: "You have been unsubscribed from all WaterLevels.org email alerts."
      end
    end

    private

    def load_token!
      @token = SubscriberToken.find_usable!(params[:token], purpose: "unsubscribe")
      @subscriber = @token.subscriber
      @raw_token = params[:token]
    rescue ActiveRecord::RecordNotFound
      # Also accept a manage token for unsubscribe-all convenience from preference center.
      begin
        manage = SubscriberToken.find_usable!(params[:token], purpose: "manage")
        @token = manage
        @subscriber = manage.subscriber
        @raw_token = params[:token]
        @using_manage_token = true
      rescue ActiveRecord::RecordNotFound
        redirect_to subscriptions_path, alert: "That unsubscribe link is invalid or has expired."
      end
    end

    def find_watch
      watch_id = params[:watch_id].presence
      return if watch_id.blank?

      @subscriber.station_watches.find_by(id: watch_id)
    end
  end
end

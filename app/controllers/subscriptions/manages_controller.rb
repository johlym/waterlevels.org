# frozen_string_literal: true

module Subscriptions
  class ManagesController < BaseController
    before_action :load_subscriber!

    def show
      @watches = @subscriber.station_watches.includes(:monitoring_location, :alert_rules).order(:id)
    end

    def update
      unless @subscriber.update(subscriber_params)
        @watches = @subscriber.station_watches.includes(:monitoring_location, :alert_rules).order(:id)
        flash.now[:alert] = @subscriber.errors.full_messages.to_sentence
        return render :show, status: :unprocessable_content
      end

      update_watch_rules!
      redirect_to subscriptions_manage_path(token: params[:token]), notice: "Preferences saved."
    end

    def destroy_watch
      watch = @subscriber.station_watches.find(params[:id])
      watch.destroy!
      redirect_to subscriptions_manage_path(token: params[:token]), notice: "Station removed from your watches."
    end

    def pause
      @subscriber.pause!
      redirect_to subscriptions_manage_path(token: params[:token]), notice: "Alerts paused."
    end

    def unpause
      @subscriber.unpause!
      redirect_to subscriptions_manage_path(token: params[:token]), notice: "Alerts resumed."
    end

    private

    def load_subscriber!
      token = SubscriberToken.find_usable!(params[:token], purpose: "manage")
      @subscriber = token.subscriber
      @manage_token = params[:token]
      if @subscriber.unsubscribed?
        redirect_to subscriptions_path, alert: "This subscription has been cancelled."
      end
    rescue ActiveRecord::RecordNotFound
      redirect_to subscriptions_path, alert: "That manage link is invalid or has expired."
    end

    def subscriber_params
      params.require(:subscriber).permit(
        :time_zone,
        :digest_hour,
        :digest_minute,
        :digest_enabled
      )
    end

    def update_watch_rules!
      watches = params.fetch(:watches, {})
      watches.each do |watch_id, attrs|
        watch = @subscriber.station_watches.find_by(id: watch_id)
        next unless watch

        sync_rule(watch, "flood_category_change", attrs[:flood_enabled])
        sync_rule(watch, "digest", attrs[:digest_enabled])
        sync_threshold_rule(watch, attrs)
      end
    end

    def sync_rule(watch, kind, enabled_param)
      rule = watch.alert_rules.find_or_initialize_by(kind: kind)
      rule.enabled = ActiveModel::Type::Boolean.new.cast(enabled_param)
      rule.params = default_params_for(kind) if rule.new_record? && rule.params.blank?
      rule.save!
    end

    def sync_threshold_rule(watch, attrs)
      enabled = ActiveModel::Type::Boolean.new.cast(attrs[:threshold_enabled])
      rule = watch.alert_rules.find_or_initialize_by(kind: "threshold")
      rule.enabled = enabled
      rule.params = {
        "parameter" => attrs[:threshold_parameter].presence || rule.param("parameter", "water_level"),
        "op" => attrs[:threshold_op].presence || rule.param("op", "above"),
        "value" => attrs[:threshold_value].presence || rule.param("value", 0),
        "duration_minutes" => (attrs[:threshold_duration_minutes].presence || rule.param("duration_minutes", 30)).to_i,
        "cooldown_minutes" => (attrs[:threshold_cooldown_minutes].presence || rule.param("cooldown_minutes", 360)).to_i,
        "hysteresis" => (attrs[:threshold_hysteresis].presence || rule.param("hysteresis", 0.2)).to_f
      }
      rule.save!
    end

    def default_params_for(kind)
      case kind
      when "flood_category_change"
        { "notify_clear" => true, "min_severity" => "action" }
      when "digest"
        { "include" => true }
      else
        {}
      end
    end
  end
end

# frozen_string_literal: true

module Subscriptions
  class VerificationsController < BaseController
    def show
      token = SubscriberToken.find_usable!(params[:token], purpose: "verify")
      subscriber = token.subscriber
      subscriber.verify!
      token.mark_used!

      subscriber.station_watches.find_each(&:ensure_default_rules!)
      raw = subscriber.manage_token!
      AlertMailer.with(subscriber: subscriber, token: raw, manage_token: raw).manage_link.deliver_later

      redirect_to subscriptions_manage_path(token: raw),
                  notice: "Email confirmed. You can manage your alert preferences below."
    rescue ActiveRecord::RecordNotFound
      redirect_to subscriptions_path, alert: "That confirmation link is invalid or has expired."
    end
  end
end

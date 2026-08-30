# frozen_string_literal: true

class AlertMailer < ApplicationMailer
  # Verify / manage-link use deliver_later — keep them on notifications_worker
  # with AlertDeliveryJob instead of the orphaned default `mailers` queue.
  self.deliver_later_queue_name = :notifications

  before_action :assign_common_params

  # Double opt-in confirmation after signup.
  def verify_email
    @verify_url = subscriptions_verify_url(token: params[:token])
    mail(to: @subscriber.email, subject: "Confirm your WaterLevels.org email alerts")
  end

  # Station signup receipt: confirm (when needed), undo this watch, plus manage.
  def subscription_confirmation
    @verify_url = subscriptions_verify_url(token: params[:token]) if params[:token].present?
    @station_name = @location&.display_name.presence || "this station"
    @station_url = gauge_url_for(@location)
    subject = if @verify_url
      "Confirm your subscription to #{@station_name}"
    else
      "You’re subscribed to #{@station_name}"
    end
    mail(to: @subscriber.email, subject: subject)
  end

  # “Here’s your manage link” after email verification or manage-link request.
  def manage_link
    @manage_url = subscriptions_manage_url(token: params[:token])
    mail(to: @subscriber.email, subject: "Your WaterLevels.org alert preferences")
  end

  def flood_category_change
    @from_category = params[:from_category]
    @to_category = params[:to_category]
    @observed_at = params[:observed_at]
    @station_url = gauge_url_for(@location)
    mail(
      to: @subscriber.email,
      subject: flood_subject
    )
  end

  def threshold_crossed
    @parameter = params[:parameter]
    @value = params[:value]
    @op = params[:op]
    @threshold = params[:threshold]
    @unit = params[:unit]
    @observed_at = params[:observed_at]
    @station_url = gauge_url_for(@location)
    mail(
      to: @subscriber.email,
      subject: threshold_subject
    )
  end

  def daily_digest
    @snapshots = Array(params[:snapshots])
    mail(
      to: @subscriber.email,
      subject: "Daily water digest — #{Time.current.strftime("%b %-d, %Y")}"
    )
  end

  # Phase F stubs — keep templates ready without delivery wiring yet.
  def rate_of_rise
    stub_phase_f!("Rate of rise")
  end

  def in_range
    stub_phase_f!("In-range")
  end

  def quiet_station
    stub_phase_f!("Quiet station")
  end

  private

  def assign_common_params
    @subscriber = params[:subscriber]
    @station_watch = params[:station_watch]
    @location = params[:location] || @station_watch&.monitoring_location
    @manage_token = params[:manage_token]
    @unsubscribe_token = params[:unsubscribe_token]
    @manage_url = subscriptions_manage_url(token: @manage_token) if @manage_token.present?
    @unsubscribe_all_url = unsubscribe_url(scope: "all")
    @unsubscribe_watch_url = unsubscribe_url(scope: "watch", watch_id: @station_watch&.id) if @station_watch
  end

  def unsubscribe_url(scope:, watch_id: nil)
    return if @unsubscribe_token.blank?

    subscriptions_unsubscribe_url(
      token: @unsubscribe_token,
      scope: scope,
      watch_id: watch_id
    )
  end

  def gauge_url_for(location)
    return root_url if location.blank?

    gauge_url(state: location.path_state, site_number_slug: location.to_param)
  end

  def flood_subject
    name = @location&.display_name.presence || "Station"
    to = (@to_category || "unknown").to_s.tr("_", " ")
    "Flood category update: #{name} → #{to}"
  end

  def threshold_subject
    name = @location&.display_name.presence || "Station"
    param = (@parameter || "reading").to_s.tr("_", " ")
    "Threshold alert: #{name} #{param}"
  end

  def stub_phase_f!(label)
    @phase_f_label = label
    @station_url = gauge_url_for(@location)
    mail(
      to: @subscriber.email,
      subject: "#{label} alert (preview) — WaterLevels.org"
    )
  end
end

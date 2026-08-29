# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  include AlertsFeatureGate

  invisible_captcha only: :create, honeypot: :subtitle, on_spam: :spam_detected

  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
  RATE_LIMIT_TO = 20
  RATE_LIMIT_WITHIN = 1.hour

  before_action :set_no_store_headers
  rate_limit to: RATE_LIMIT_TO,
             within: RATE_LIMIT_WITHIN,
             only: :create,
             by: -> { request.remote_ip },
             store: (Rails.env.test? ? RATE_LIMIT_STORE : Rails.cache)

  # Gauge pages are edge-cached without a Rails session, so embedded signup
  # forms cannot carry a valid CSRF token. Create is protected by honeypot,
  # optional Turnstile, and IP rate limiting instead.
  skip_forgery_protection only: :create

  def new
    @monitoring_location = find_optional_location
    @email = params[:email].to_s
    @time_zone = SubscriberTimeZones.normalize(params[:time_zone])
    @digest_enabled = params[:digest_enabled] != "0"
  end

  def create
    if manage_link_request?
      return request_manage_link
    end

    signup_watch
  end

  private

  def enable_session?
    true
  end

  def set_no_store_headers
    response.set_header("Cache-Control", "private, no-store")
  end

  def manage_link_request?
    params[:monitoring_location_id].blank? && params[:intent].to_s == "manage_link"
  end

  def request_manage_link
    unless turnstile_ok?
      flash.now[:alert] = "Please complete the bot check and try again."
      return render :new, status: :unprocessable_content
    end

    email = params[:email].to_s.strip.downcase
    subscriber = Subscriber.find_by(email: email)

    if subscriber.nil? || subscriber.unsubscribed?
      redirect_to subscriptions_path, notice: "If that address is subscribed, a manage link is on its way."
      return
    end

    raw = subscriber.manage_token!
    AlertMailer.with(subscriber: subscriber, token: raw, manage_token: raw).manage_link.deliver_later
    redirect_to subscriptions_path, notice: "If that address is subscribed, a manage link is on its way."
  end

  def signup_watch
    unless turnstile_ok?
      @monitoring_location = find_optional_location
      flash.now[:alert] = "Please complete the bot check and try again."
      return render :new, status: :unprocessable_content
    end

    location = MonitoringLocation.find_by(id: params[:monitoring_location_id])
    if location.nil?
      flash.now[:alert] = "Choose a monitoring station to watch."
      return render :new, status: :unprocessable_content
    end

    email = params[:email].to_s.strip.downcase
    time_zone = SubscriberTimeZones.normalize(params[:time_zone])
    digest_enabled = ActiveModel::Type::Boolean.new.cast(params.fetch(:digest_enabled, true))

    subscriber = Subscriber.find_or_initialize_by(email: email)
    subscriber.time_zone = time_zone if subscriber.new_record? || subscriber.time_zone.blank?
    subscriber.digest_enabled = digest_enabled if subscriber.new_record?
    # Re-subscribe soft-unsubscribed addresses.
    if subscriber.unsubscribed?
      subscriber.unsubscribed_at = nil
      subscriber.verified_at = nil
    end

    unless subscriber.save
      @monitoring_location = location
      flash.now[:alert] = subscriber.errors.full_messages.to_sentence.presence || "Could not save subscription."
      return render :new, status: :unprocessable_content
    end

    watch = subscriber.station_watches.find_or_create_by!(monitoring_location: location)
    watch.ensure_default_rules!

    if subscriber.verified?
      raw = subscriber.manage_token!
      AlertMailer.with(
        subscriber: subscriber,
        token: raw,
        manage_token: raw,
        station_watch: watch,
        location: location
      ).manage_link.deliver_later
      redirect_to subscriptions_path(monitoring_location_id: location.id),
                  notice: "You’re subscribed. Check your email for a link to manage alerts."
    else
      raw = subscriber.issue_token!(purpose: "verify", expires_at: 48.hours.from_now)
      AlertMailer.with(subscriber: subscriber, token: raw, station_watch: watch, location: location)
        .verify_email.deliver_later
      redirect_to subscriptions_path(monitoring_location_id: location.id),
                  notice: "Check your email to confirm your address and finish setup."
    end
  end

  def find_optional_location
    id = params[:monitoring_location_id].presence
    return if id.blank?

    MonitoringLocation.find_by(id: id)
  end

  def turnstile_ok?
    return true if ENV["TURNSTILE_SECRET"].blank?

    TurnstileVerification.new(
      token: params["cf-turnstile-response"],
      remote_ip: request.remote_ip
    ).success?
  end

  def spam_detected
    redirect_to subscriptions_path, notice: "Thanks — check your email if a confirmation is needed."
  end
end

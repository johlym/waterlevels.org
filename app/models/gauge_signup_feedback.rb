# frozen_string_literal: true

# Query-param notices for the cookieless, edge-cached station page.
# Rails flash needs a session, which gauge pages skip so Cloudflare can cache.
module GaugeSignupFeedback
  NOTICES = {
    "sent" => "Check your email to confirm this subscription. The message includes a link to undo.",
    "subscribed" => "You’re subscribed. Check your email for a confirmation with a link to undo."
  }.freeze

  ALERTS = {
    "bot" => "Please complete the bot check and try again.",
    "invalid" => "Could not save subscription.",
    "max" => "This address already watches the maximum number of stations. Remove one from your manage link first.",
    "station" => "Choose a monitoring station to watch."
  }.freeze

  module_function

  def normalize(key)
    value = key.to_s
    return value if NOTICES.key?(value) || ALERTS.key?(value)

    nil
  end

  def notice_for(key)
    NOTICES[normalize(key)]
  end

  def alert_for(key)
    ALERTS[normalize(key)]
  end
end

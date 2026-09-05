class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "WaterLevels.org <hello@waterlevels.org>")
  layout "mailer"
  helper MailerHelper
end


class ContactMailer < ApplicationMailer
  # Infrequent contact-form mail; drain with the default worker dyno rather
  # than notifications_worker (alerts / digests).
  self.deliver_later_queue_name = :default

  def contact_email
    @name = params[:name]
    @email = params[:email]
    @body = params[:message]
    mail(
      to: ENV.fetch("CONTACT_TO_EMAIL", "hello@waterlevels.org"),
      reply_to: @email,
      subject: "[WaterLevels.org] #{params[:subject]}"
    )
  end
end

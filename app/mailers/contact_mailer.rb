class ContactMailer < ApplicationMailer
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

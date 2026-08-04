class ContactsController < ApplicationController
  invisible_captcha only: :create, honeypot: :subtitle, on_spam: :spam_detected

  def create
    @contact_message = ContactMessage.new(contact_params)
    @contact_message.turnstile_token = params["cf-turnstile-response"]
    @contact_message.remote_ip = request.remote_ip

    if @contact_message.deliver
      redirect_to contact_path, notice: "Thanks — your message has been sent."
    else
      flash.now[:alert] = @contact_message.errors.full_messages.to_sentence.presence || "Could not send your message."
      render template: "pages/contact", status: :unprocessable_content
    end
  end

  private

  def enable_session?
    true
  end

  def contact_params
    params.require(:contact_message).permit(:name, :email, :subject, :message)
  end

  def spam_detected
    redirect_to contact_path, notice: "Thanks — your message has been sent."
  end
end

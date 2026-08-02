module Contact
  class FormComponent < ViewComponent::Base
    def initialize(contact_message: ContactMessage.new)
      @contact_message = contact_message
    end

    def site_key
      ENV.fetch("TURNSTILE_SITE_KEY", "")
    end
  end
end

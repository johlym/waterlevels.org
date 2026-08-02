module Contact
  class FormComponent < ViewComponent::Base
    # Public site key from the existing Cloudflare Turnstile widget.
    SITE_KEY = "0x4AAAAAAEEJcVkiLjrvpdvr".freeze

    def initialize(contact_message: ContactMessage.new)
      @contact_message = contact_message
    end

    def site_key
      ENV.fetch("TURNSTILE_SITE_KEY", SITE_KEY)
    end
  end
end

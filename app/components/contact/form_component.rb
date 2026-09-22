module Contact
  class FormComponent < ViewComponent::Base
    # Public site key from the existing Cloudflare Turnstile widget.
    SITE_KEY = "0x4AAAAAAEEJcVkiLjrvpdvr".freeze

    def initialize(contact_message: ContactMessage.new)
      @contact_message = contact_message
    end

    def self.site_key
      ENV["TURNSTILE_SITE_KEY"].presence || SITE_KEY
    end

    def site_key
      self.class.site_key
    end
  end
end

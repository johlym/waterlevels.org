module Footer
  class ThinComponent < ViewComponent::Base
    def initialize(year: Time.current.year)
      @year = year
    end
  end
end

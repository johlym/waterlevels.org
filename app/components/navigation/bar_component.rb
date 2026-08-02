module Navigation
  class BarComponent < ViewComponent::Base
    def initialize(brand: "WaterLevels.org", overlay: false)
      @brand = brand
      @overlay = overlay
    end

    def shell_classes
      classes = [ "site-header" ]
      classes << "is-overlay" if @overlay
      classes.join(" ")
    end
  end
end

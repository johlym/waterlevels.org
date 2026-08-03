module Navigation
  class BarComponent < ViewComponent::Base
    def initialize(brand: "WaterLevels.org", overlay: false, map_controls: false)
      @brand = brand
      @overlay = overlay
      @map_controls = map_controls
    end

    def shell_classes
      classes = [ "site-header" ]
      classes << "is-overlay" if @overlay
      classes << "has-map-controls" if @map_controls
      classes.join(" ")
    end
  end
end

module Navigation
  class BarComponent < ViewComponent::Base
    def initialize(brand: "WaterLevels.org", map_controls: false)
      @brand = brand
      @map_controls = map_controls
    end
  end
end

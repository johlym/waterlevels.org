module States
  class LocationsTableComponent < ViewComponent::Base
    def initialize(locations:)
      @locations = locations
    end
  end
end

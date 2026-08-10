module Admin
  class StationsController < BaseController
    def index
      query = params[:q].to_s.strip
      return if query.blank?

      @query = query
      location = StationInspector.find(query)
      if location
        redirect_to admin_station_path(location.site_number)
        return
      end

      @matches = MonitoringLocation.search(query).limit(25)
    end

    def show
      @location = StationInspector.find(params[:site_number])
      unless @location
        redirect_to admin_stations_path, alert: "No station found for #{params[:site_number]}."
        return
      end

      @report = StationInspector.report(@location)
    end
  end
end

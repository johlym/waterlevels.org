class TemperatureUnitsController < ApplicationController
  def update
    unit = params[:unit].to_s.downcase
    unit = "f" unless %w[f c].include?(unit)
    cookies.permanent[:temperature_unit] = {
      value: unit,
      httponly: false,
      same_site: :lax
    }
    head :no_content
  end
end

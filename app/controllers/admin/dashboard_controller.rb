module Admin
  class DashboardController < BaseController
    SECTIONS = AdminDashboardStats::SECTIONS

    def show
      # Shell only — each section loads via Turbo Frame so heavy aggregates
      # do not block first paint.
    end

    def section
      @section = params[:section].to_s.to_sym
      unless SECTIONS.include?(@section)
        head :not_found
        return
      end

      @stats = AdminDashboardStats.section(@section)
      render :section, layout: false
    end
  end
end

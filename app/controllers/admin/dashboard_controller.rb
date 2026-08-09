module Admin
  class DashboardController < BaseController
    SECTIONS = AdminDashboardStats::SECTIONS

    def show
      # Shell only — each section loads via Turbo Frame so heavy aggregates
      # do not block first paint. Frames are filled sequentially (Stimulus)
      # so a 3-thread Puma dyno is not stampeded by six cold aggregates.
    end

    def section
      @section = params[:section].to_s.to_sym
      unless SECTIONS.include?(@section)
        head :not_found
        return
      end

      AdminDashboardStats.with_statement_timeout do
        @stats = AdminDashboardStats.section(@section)
      end
      render :section, layout: false
    rescue ActiveRecord::QueryCanceled => e
      Rails.logger.warn("[admin/dashboard#section] timeout section=#{@section}: #{e.message}")
      @error = "This section timed out while aggregating. Retry in a moment — cached values may already be warming."
      render :section_error, layout: false, status: :service_unavailable
    rescue ActiveRecord::StatementInvalid => e
      raise unless statement_timeout?(e)

      Rails.logger.warn("[admin/dashboard#section] statement timeout section=#{@section}: #{e.message}")
      @error = "This section timed out while aggregating. Retry in a moment — cached values may already be warming."
      render :section_error, layout: false, status: :service_unavailable
    end

    private

    def statement_timeout?(error)
      message = error.message.to_s
      message.match?(/statement timeout|canceling statement due to statement timeout/i)
    end
  end
end

module Admin
  class DashboardController < BaseController
    def show
      @stats = AdminDashboardStats.snapshot
    end
  end
end

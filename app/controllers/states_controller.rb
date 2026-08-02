class StatesController < ApplicationController
  include CacheableResponse

  def show
    @state_code = params[:state].to_s.downcase
    raise ActiveRecord::RecordNotFound unless @state_code.match?(/\A[a-z]{2}\z/)

    @listing = StateListingCache.fetch(@state_code)
    cache_public!(tags: [ "state:#{@state_code}" ])
  end
end

# frozen_string_literal: true

MetaTags.configure do |config|
  # noindex and a canonical URL contradict each other. Private alert links
  # and the admin area stay out of the index without also nominating a URL.
  config.skip_canonical_links_on_noindex = true
end

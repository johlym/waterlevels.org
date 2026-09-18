# RFC 9727 API catalog (application/linkset+json).
# Does not advertise first-party /api/* — those endpoints are website-only.
class ApiCatalog
  PROFILE = "https://www.rfc-editor.org/info/rfc9727"
  CONTENT_TYPE = "application/linkset+json; profile=\"#{PROFILE}\""
  SELF_LINK = '</.well-known/api-catalog>; rel="api-catalog"; type="application/linkset+json"'

  USGS_API = "https://api.waterdata.usgs.gov/"
  NWPS_API = "https://api.water.noaa.gov/nwps/v1/docs/"
  USBR_API = "https://data.usbr.gov/rise-api"
  USACE_API = "https://cwms-data.usace.army.mil/cwms-data/"

  DISCOVERY_LINKS = [
    SELF_LINK,
    '</disclosures>; rel="service-doc"; type="text/html"',
    '</faq>; rel="service-doc"; type="text/html"',
    '</llms.txt>; rel="describedby"; type="text/plain"'
  ].freeze

  def self.discovery_link_header
    DISCOVERY_LINKS.join(", ")
  end

  def self.linkset(base_url:)
    base = base_url.to_s.chomp("/")
    {
      "linkset" => [
        {
          "anchor" => "#{base}/",
          "service-doc" => [
            { "href" => "#{base}/disclosures", "type" => "text/html" },
            { "href" => "#{base}/faq", "type" => "text/html" }
          ],
          "describedby" => [
            { "href" => "#{base}/llms.txt", "type" => "text/plain" }
          ]
        },
        {
          "anchor" => USGS_API,
          "service-desc" => [
            { "href" => USGS_API, "type" => "text/html" }
          ],
          "service-doc" => [
            { "href" => "#{base}/disclosures", "type" => "text/html" },
            { "href" => "#{base}/faq", "type" => "text/html" }
          ]
        },
        {
          "anchor" => NWPS_API,
          "service-desc" => [
            { "href" => NWPS_API, "type" => "text/html" }
          ],
          "service-doc" => [
            { "href" => "#{base}/disclosures", "type" => "text/html" }
          ]
        },
        {
          "anchor" => USBR_API,
          "service-desc" => [
            { "href" => USBR_API, "type" => "text/html" }
          ],
          "service-doc" => [
            { "href" => "#{base}/disclosures", "type" => "text/html" }
          ]
        },
        {
          "anchor" => USACE_API,
          "service-desc" => [
            { "href" => USACE_API, "type" => "text/html" }
          ],
          "service-doc" => [
            { "href" => "#{base}/disclosures", "type" => "text/html" }
          ]
        }
      ]
    }
  end
end

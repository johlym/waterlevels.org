require "test_helper"
require "stringio"

class NetworkStationsTest < ActiveSupport::TestCase
  setup do
    @origin = create(
      :monitoring_location,
      site_number: "12113000",
      usgs_monitoring_location_id: "USGS-12113000",
      latitude: 47.30,
      longitude: -122.18
    )
    @near_later = create(
      :monitoring_location,
      site_number: "12113100",
      usgs_monitoring_location_id: "USGS-12113100",
      name: "Near but later on the bend",
      slug: "near-but-later-on-the-bend",
      latitude: 47.301,
      longitude: -122.179
    )
    @far_earlier = create(
      :monitoring_location,
      site_number: "12106700",
      usgs_monitoring_location_id: "USGS-12106700",
      name: "Farther but earlier on the stream",
      slug: "farther-but-earlier-on-the-stream",
      latitude: 47.3002,
      longitude: -122.175
    )
    @third = create(
      :monitoring_location,
      site_number: "12106500",
      usgs_monitoring_location_id: "USGS-12106500",
      name: "Third on-stream",
      slug: "third-on-stream",
      latitude: 47.3004,
      longitude: -122.172
    )
    @off_path = create(
      :monitoring_location,
      site_number: "12107300",
      usgs_monitoring_location_id: "USGS-12107300",
      name: "Icy Creek off the mainstem",
      slug: "icy-creek-off-the-mainstem",
      latitude: 47.40,
      longitude: -122.18
    )
  end

  test "intersects the catalog, drops origin and off-path, and orders by flowline not haversine" do
    client = FakeNldi.new(
      sites: {
        "UM" => um_sites,
        "DM" => []
      },
      flowlines: {
        "UM" => um_flowlines,
        "DM" => []
      }
    )

    NetworkStations.refresh_one(@origin, client: client)
    @origin.reload

    assert_equal [ @far_earlier.id, @near_later.id ], @origin.upstream_station_ids
    assert_empty @origin.downstream_station_ids
    assert @origin.network_synced_at.present?
    refute_includes @origin.upstream_station_ids, @origin.id
    refute_includes @origin.upstream_station_ids, @off_path.id
    refute_includes @origin.upstream_station_ids, @third.id
  end

  test "keeps only the origin-reach side matching the navigation mode" do
    downstream_same_reach = create(
      :monitoring_location,
      site_number: "12113200",
      usgs_monitoring_location_id: "USGS-12113200",
      latitude: 47.2998,
      longitude: -122.181
    )
    client = FakeNldi.new(
      sites: {
        "UM" => [
          site(@origin.usgs_monitoring_location_id, comid: 10, measure: 50),
          site(downstream_same_reach.usgs_monitoring_location_id, comid: 10, measure: 20),
          site(@far_earlier.usgs_monitoring_location_id, comid: 10, measure: 80)
        ],
        "DM" => [
          site(@origin.usgs_monitoring_location_id, comid: 10, measure: 50),
          site(downstream_same_reach.usgs_monitoring_location_id, comid: 10, measure: 20),
          site(@far_earlier.usgs_monitoring_location_id, comid: 10, measure: 80)
        ]
      },
      flowlines: {
        "UM" => [ flowline(10, [ [ -122.181, 47.2998 ], [ -122.18, 47.30 ], [ -122.175, 47.3002 ] ]) ],
        "DM" => [ flowline(10, [ [ -122.18, 47.30 ], [ -122.181, 47.2998 ] ]) ]
      }
    )

    NetworkStations.refresh_one(@origin, client: client)
    @origin.reload

    assert_equal [ @far_earlier.id ], @origin.upstream_station_ids
    assert_equal [ downstream_same_reach.id ], @origin.downstream_station_ids
  end

  test "404 leaves empty neighbor lists and stamps network_synced_at" do
    stub_request(:get, %r{\Ahttps://api\.water\.usgs\.gov/nldi/})
      .to_return(status: 404, body: "", headers: { "Content-Type" => "application/json" })

    NetworkStations.refresh_one(@origin)
    @origin.reload

    assert_empty @origin.upstream_station_ids
    assert_empty @origin.downstream_station_ids
    assert @origin.network_synced_at.present?
  end

  test "retries a stamped row that still has empty neighbor lists" do
    @origin.update!(
      upstream_station_ids: [],
      downstream_station_ids: [],
      network_synced_at: 1.hour.ago
    )
    client = FakeNldi.new(
      sites: {
        "UM" => um_sites,
        "DM" => []
      },
      flowlines: {
        "UM" => um_flowlines,
        "DM" => []
      }
    )

    refreshed = NetworkStations.refresh([ @origin ], client: client)

    assert_equal 1, refreshed
    assert_equal [ @far_earlier.id, @near_later.id ], @origin.reload.upstream_station_ids
  end

  test "skips locations whose network graph is still fresh" do
    @origin.update!(
      upstream_station_ids: [ @far_earlier.id ],
      downstream_station_ids: [],
      network_synced_at: 1.hour.ago
    )
    client = FakeNldi.new(sites: { "UM" => :should_not_run, "DM" => :should_not_run }, flowlines: {})

    refreshed = NetworkStations.refresh([ @origin ], client: client)

    assert_equal 0, refreshed
    assert_equal [ @far_earlier.id ], @origin.reload.upstream_station_ids
  end

  test "refreshes when a stored neighbor is no longer in the catalog" do
    @origin.update!(
      upstream_station_ids: [ 9_999_999 ],
      network_synced_at: 1.hour.ago
    )
    client = FakeNldi.new(
      sites: { "UM" => [], "DM" => [] },
      flowlines: { "UM" => [], "DM" => [] }
    )

    refreshed = NetworkStations.refresh([ @origin ], client: client)

    assert_equal 1, refreshed
    assert_empty @origin.reload.upstream_station_ids
  end

  test "reports pending and per-station neighbor counts on progress" do
    io = StringIO.new
    progress = SyncProgress.new("nldi", io: io, logger: nil, every: 1)
    client = FakeNldi.new(
      sites: {
        "UM" => um_sites,
        "DM" => []
      },
      flowlines: {
        "UM" => um_flowlines,
        "DM" => []
      }
    )

    NetworkStations.refresh([ @origin ], client: client, progress: progress)

    output = io.string
    assert_match(/nldi: locations=1 pending=1/, output)
    assert_match(/usgs_id=#{@origin.usgs_monitoring_location_id} upstream=2 downstream=0 refreshed=1\/1/, output)
  end

  test "does not hold a database checkout across NLDI HTTP" do
    client = FakeNldi.new(
      sites: {
        "UM" => um_sites,
        "DM" => []
      },
      flowlines: {
        "UM" => um_flowlines,
        "DM" => []
      }
    )

    NetworkStations.refresh_one(@origin, client: client)

    assert_operator client.http_calls, :>=, 2
    assert_empty client.checked_out_during_http
  end

  test "limit refreshes a prefix and a later call resumes" do
    client = FakeNldi.new(
      sites: { "UM" => [], "DM" => [] },
      flowlines: { "UM" => [], "DM" => [] }
    )
    first, second = [ @origin, @near_later ].sort_by(&:id)

    refreshed = NetworkStations.refresh([ first, second ], client: client, limit: 1)

    assert_equal 1, refreshed
    assert first.reload.network_synced_at.present?
    assert_nil second.reload.network_synced_at

    refreshed = NetworkStations.refresh([ first, second ], client: client, limit: 1)

    assert_equal 1, refreshed
    assert second.reload.network_synced_at.present?
  end

  test "continues past an NLDI error without stamping the failed station" do
    client = FakeNldi.new(
      sites: { "UM" => [], "DM" => [] },
      flowlines: { "UM" => [], "DM" => [] }
    )
    client.fail_usgs_ids << @origin.usgs_monitoring_location_id

    refreshed = NetworkStations.refresh([ @origin, @near_later ], client: client)

    assert_equal 1, refreshed
    @origin.reload
    @near_later.reload
    assert_nil @origin.network_synced_at
    assert @near_later.network_synced_at.present?
  end

  test "force refreshes a still-fresh location" do
    @origin.update!(
      upstream_station_ids: [ @far_earlier.id ],
      network_synced_at: 1.hour.ago
    )
    client = FakeNldi.new(
      sites: { "UM" => [], "DM" => [] },
      flowlines: { "UM" => [], "DM" => [] }
    )

    refreshed = NetworkStations.refresh([ @origin ], client: client, force: true)

    assert_equal 1, refreshed
    assert_empty @origin.reload.upstream_station_ids
  end

  private

  class FakeNldi
    attr_reader :http_calls, :checked_out_during_http, :fail_usgs_ids

    def initialize(sites:, flowlines:)
      @sites = sites
      @flowlines = flowlines
      @http_calls = 0
      @checked_out_during_http = []
      @fail_usgs_ids = []
    end

    def navigate_sites(usgs_id, mode:, distance_km:)
      raise Nldi::Client::Error, "forced failure" if @fail_usgs_ids.include?(usgs_id)

      record_http!("sites/#{mode}")
      value = @sites.fetch(mode)
      raise "unexpected NLDI sites call" if value == :should_not_run

      value
    end

    def navigate_flowlines(_usgs_id, mode:, distance_km:)
      record_http!("flowlines/#{mode}")
      @flowlines.fetch(mode, [])
    end

    private

    def record_http!(label)
      @http_calls += 1
      return unless ActiveRecord::Base.connection_pool.active_connection?

      @checked_out_during_http << label
    end
  end

  def um_sites
    [
      site(@origin.usgs_monitoring_location_id, comid: 10, measure: 40),
      site(@far_earlier.usgs_monitoring_location_id, comid: 10, measure: 80),
      site(@near_later.usgs_monitoring_location_id, comid: 20, measure: 30),
      site(@third.usgs_monitoring_location_id, comid: 30, measure: 10),
      site(@off_path.usgs_monitoring_location_id, comid: 10, measure: 70),
      site("USGS-99999999", comid: 10, measure: 90)
    ]
  end

  def um_flowlines
    [
      flowline(10, [ [ -122.18, 47.30 ], [ -122.175, 47.3002 ], [ -122.172, 47.3004 ] ]),
      flowline(20, [ [ -122.172, 47.3004 ], [ -122.179, 47.301 ] ]),
      flowline(30, [ [ -122.179, 47.301 ], [ -122.171, 47.3006 ] ])
    ]
  end

  def site(identifier, comid:, measure:)
    {
      "id" => identifier,
      "properties" => {
        "identifier" => identifier,
        "comid" => comid,
        "measure" => measure
      }
    }
  end

  def flowline(comid, coordinates)
    {
      "id" => comid,
      "properties" => { "nhdplus_comid" => comid },
      "geometry" => { "type" => "LineString", "coordinates" => coordinates }
    }
  end
end

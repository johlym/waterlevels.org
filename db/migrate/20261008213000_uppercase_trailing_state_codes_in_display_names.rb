class UppercaseTrailingStateCodesInDisplayNames < ActiveRecord::Migration[8.1]
  def up
    say_with_time "reformat display_name and search_name; leave slug unchanged" do
      MonitoringLocation.find_each(batch_size: 500) do |location|
        display = Usgs::LocationNames.format(location.name)
        search = display.downcase
        next if location.display_name == display && location.search_name == search

        location.update_columns(
          display_name: display,
          search_name: search
        )
      end
    end
  end

  def down
    # Prior display casing is not stored separately from the raw USGS name.
  end
end

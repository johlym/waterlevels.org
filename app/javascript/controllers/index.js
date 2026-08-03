import { application } from "./application"

import MapController from "./map_controller"
import HydrographController from "./hydrograph_controller"
import ParameterToggleController from "./parameter_toggle_controller"
import TemperatureUnitController from "./temperature_unit_controller"
import MobileNavController from "./mobile_nav_controller"
import StateDirectoryController from "./state_directory_controller"
import StationSearchController from "./station_search_controller"
import FaqController from "./faq_controller"

application.register("map", MapController)
application.register("hydrograph", HydrographController)
application.register("parameter-toggle", ParameterToggleController)
application.register("temperature-unit", TemperatureUnitController)
application.register("mobile-nav", MobileNavController)
application.register("state-directory", StateDirectoryController)
application.register("station-search", StationSearchController)
application.register("faq", FaqController)

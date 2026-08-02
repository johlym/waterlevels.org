import { application } from "./application"

import MapController from "./map_controller"
import HydrographController from "./hydrograph_controller"
import ParameterToggleController from "./parameter_toggle_controller"
import TemperatureUnitController from "./temperature_unit_controller"

application.register("map", MapController)
application.register("hydrograph", HydrographController)
application.register("parameter-toggle", ParameterToggleController)
application.register("temperature-unit", TemperatureUnitController)

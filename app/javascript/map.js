import MapController from "./controllers/map_controller"
import RelatedMapController from "./controllers/related_map_controller"

window.Stimulus.register("map", MapController)
window.Stimulus.register("related-map", RelatedMapController)

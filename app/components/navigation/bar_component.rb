module Navigation
  class BarComponent < ViewComponent::Base
    def initialize(brand: "WaterLevels.org", map_controls: false, overlay: false)
      @brand = brand
      @map_controls = map_controls
      @overlay = overlay
    end

    def shell_classes
      if @overlay
        "absolute inset-x-0 top-0 z-20 border-b border-white/10 bg-rolling-stone-950/55 text-white backdrop-blur-md dark:border-white/10 dark:bg-rolling-stone-950/70"
      else
        "relative z-20 border-b border-rolling-stone-950/5 bg-white/90 backdrop-blur dark:border-white/10 dark:bg-rolling-stone-950/90 dark:shadow-none"
      end
    end

    def brand_classes
      if @overlay
        "text-base font-semibold tracking-tight text-white"
      else
        "text-base font-semibold tracking-tight text-rolling-stone-950 dark:text-white"
      end
    end

    def link_classes
      if @overlay
        "rounded-md px-3 py-2 text-base text-white/80 hover:bg-white/10 hover:text-white sm:text-sm"
      else
        "rounded-md px-3 py-2 text-base text-rolling-stone-600 hover:bg-rolling-stone-950/5 hover:text-rolling-stone-950 dark:text-rolling-stone-300 dark:hover:bg-white/5 dark:hover:text-white sm:text-sm"
      end
    end

    def locate_classes
      if @overlay
        "rounded-md bg-white px-3 py-2 text-base font-medium text-rolling-stone-950 hover:bg-rolling-stone-100 sm:text-sm"
      else
        "rounded-md bg-smalt-700 px-3 py-2 text-base font-medium text-white hover:bg-smalt-800 dark:bg-smalt-400 dark:text-rolling-stone-950 dark:hover:bg-smalt-300 sm:text-sm"
      end
    end

    def menu_button_classes
      if @overlay
        "inline-flex items-center justify-center rounded-md p-2 text-white hover:bg-white/10 lg:hidden"
      else
        "inline-flex items-center justify-center rounded-md p-2 text-rolling-stone-700 hover:bg-rolling-stone-950/5 dark:text-rolling-stone-200 dark:hover:bg-white/5 lg:hidden"
      end
    end

    def mobile_panel_classes
      if @overlay
        "border-t border-white/10 bg-rolling-stone-950/90 px-4 py-3 lg:hidden"
      else
        "border-t border-rolling-stone-950/5 bg-white px-4 py-3 dark:border-white/10 dark:bg-rolling-stone-950 lg:hidden"
      end
    end
  end
end

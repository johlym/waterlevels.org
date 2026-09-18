module Usbr
  module ParameterCodes
    ELEVATION = "USBR:2"
    STORAGE = "USBR:3"

    LABELS = {
      ELEVATION => "Lake/reservoir elevation",
      STORAGE => "Lake/reservoir storage"
    }.freeze

    RISE_TO_CODE = {
      2 => ELEVATION,
      3 => STORAGE
    }.freeze

    MEASUREMENT_KINDS = {
      ELEVATION => "water_level"
    }.freeze

    module_function

    def code_for_rise_parameter_id(parameter_id)
      RISE_TO_CODE[parameter_id.to_i]
    end

    def label_for(parameter_code, fallback: nil)
      LABELS[parameter_code.to_s].presence || fallback.presence || parameter_code.to_s.presence || "Measurement"
    end

    def measurement_kind_for(parameter_code)
      MEASUREMENT_KINDS[parameter_code.to_s]
    end

    def water_level?(parameter_code)
      parameter_code.to_s == ELEVATION
    end

    def preference_rank(parameter_code)
      water_level?(parameter_code) ? 0 : 99
    end
  end
end

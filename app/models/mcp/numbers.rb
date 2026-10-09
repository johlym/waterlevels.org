module Mcp
  module Numbers
    module_function

    def round(value, digits: 3)
      return if value.nil?

      value.to_f.round(digits)
    end

    def fahrenheit(celsius)
      return if celsius.nil?

      round(celsius.to_f * 9.0 / 5.0 + 32)
    end

    def fahrenheit_delta(delta_c)
      return if delta_c.nil?

      round(delta_c.to_f * 9.0 / 5.0)
    end
  end
end

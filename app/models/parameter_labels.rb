module ParameterLabels
  module_function

  def label_for(parameter_code, fallback: nil)
    code = parameter_code.to_s
    if code.start_with?("USBR:")
      Usbr::ParameterCodes.label_for(code, fallback: fallback)
    elsif code.start_with?("USACE:")
      Usace::ParameterCodes.label_for(code, fallback: fallback)
    elsif code.start_with?("NWPS:")
      Nwps::ParameterCodes.label_for(code, fallback: fallback)
    else
      Usgs::ParameterCodes.label_for(code, fallback: fallback)
    end
  end

  def preference_rank(parameter_code)
    code = parameter_code.to_s
    if code.start_with?("USBR:")
      Usbr::ParameterCodes.preference_rank(code)
    elsif code.start_with?("USACE:")
      Usace::ParameterCodes.preference_rank(code)
    elsif code.start_with?("NWPS:")
      Nwps::ParameterCodes.preference_rank(code)
    else
      Usgs::ParameterCodes.preference_rank(code)
    end
  end
end

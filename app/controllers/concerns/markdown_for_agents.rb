# Serve a markdown twin when agents send Accept: text/markdown.
# Rails already registers text/markdown as :md. Force HTML templates first so
# missing show.md views do not 406, then convert the rendered HTML.
module MarkdownForAgents
  extend ActiveSupport::Concern

  included do
    before_action :render_html_for_markdown_negotiation
    after_action :negotiate_markdown_for_agents
  end

  private

  def markdown_request?
    accept = request.get_header("HTTP_ACCEPT").to_s
    return false if accept.blank?

    markdown_q = accept_quality(accept, "text/markdown")
    return false if markdown_q.nil?

    html_q = accept_quality(accept, "text/html")
    html_q.nil? || markdown_q >= html_q
  end

  def render_html_for_markdown_negotiation
    request.format = :html if markdown_request?
  end

  def negotiate_markdown_for_agents
    return unless html_response?

    append_vary_accept
    return unless markdown_request? && response.successful?

    markdown = HtmlToMarkdown.convert(response.body)
    response.body = markdown
    response.content_type = "text/markdown; charset=utf-8"
    response.set_header("x-markdown-tokens", HtmlToMarkdown.token_count(markdown).to_s)
  end

  def html_response?
    response.media_type.to_s.include?("html")
  end

  def append_vary_accept
    existing = response.get_header("Vary").to_s.split(",").map(&:strip).reject(&:blank?)
    return if existing.any? { |value| value.casecmp("Accept").zero? }

    response.set_header("Vary", (existing + [ "Accept" ]).join(", "))
  end

  def accept_quality(accept, mime)
    accept.split(",").each do |part|
      media, *params = part.split(";").map(&:strip)
      next unless media.downcase == mime

      q_param = params.find { |param| param.downcase.start_with?("q=") }
      return q_param ? q_param.split("=", 2).last.to_f : 1.0
    end
    nil
  end
end

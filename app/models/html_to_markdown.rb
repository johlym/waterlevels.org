# Converts HTML pages to a readable markdown twin for Accept: text/markdown.
class HtmlToMarkdown
  CHROME_SELECTOR = "script, style, noscript, svg, template, dialog, header, footer, nav, [aria-hidden='true']"
  BLOCK_TAGS = %w[p h1 h2 h3 h4 h5 h6 ul ol pre blockquote table hr div section article main].freeze

  def self.convert(html)
    new(html).to_markdown
  end

  def self.token_count(markdown)
    (markdown.to_s.length / 4.0).ceil
  end

  def initialize(html)
    @doc = Nokogiri::HTML5.parse(html.to_s)
  end

  def to_markdown
    title = @doc.at_css("title")&.text.to_s.squish
    chunks = []
    chunks << "# #{title}" if title.present?

    hero = @doc.at_css(".page-hero")
    main = @doc.at_css("main#main, #main, main")
    if hero || main
      chunks << render_blocks(hero) if hero
      chunks << render_blocks(main) if main
    else
      @doc.css(CHROME_SELECTOR).remove
      body = @doc.at_css("body") || @doc
      chunks << render_blocks(body)
    end

    "#{chunks.filter_map { |chunk| chunk.to_s.strip.presence }.join("\n\n")}\n"
  end

  private

  def render_blocks(node)
    node.children.filter_map { |child| render_block(child) }.join("\n\n").gsub(/\n{3,}/, "\n\n")
  end

  def render_block(node)
    return collapse_text(node.text) if node.text?
    return if node.comment? || skip_tag?(node)

    case node.name
    when "h1", "h2", "h3", "h4", "h5", "h6"
      text = render_inline(node).strip
      "#{"#" * node.name[1].to_i} #{text}" if text.present?
    when "p"
      render_inline(node).strip.presence
    when "ul"
      render_list(node, ordered: false)
    when "ol"
      render_list(node, ordered: true)
    when "pre"
      "```\n#{node.text.gsub(/\A\n+|\n+\z/, "")}\n```"
    when "blockquote"
      text = render_inline(node).strip
      text.lines.map { |line| "> #{line.rstrip}" }.join("\n") if text.present?
    when "table"
      render_table(node)
    when "hr"
      "---"
    when "br"
      nil
    else
      if contains_block?(node)
        render_blocks(node).presence
      else
        render_inline(node).strip.presence
      end
    end
  end

  def render_list(node, ordered:)
    items = node.element_children.select { |child| child.name == "li" }
    return if items.empty?

    items.each_with_index.filter_map do |item, index|
      prefix = ordered ? "#{index + 1}. " : "- "
      content = render_list_item(item)
      "#{prefix}#{content}" if content.present?
    end.join("\n").presence
  end

  def render_list_item(node)
    inline = +""
    nested = []
    node.children.each do |child|
      if child.element? && %w[ul ol].include?(child.name)
        list = render_list(child, ordered: child.name == "ol")
        nested << list if list.present?
      else
        inline << render_inline_node(child).to_s
      end
    end

    parts = [ inline.gsub(/[ \t\f\r\n]+/, " ").strip ]
    parts.concat(nested.map { |list| list.gsub(/^/, "  ") })
    parts.compact_blank.join("\n")
  end

  def render_table(node)
    rows = node.css("tr").map do |row|
      row.css("th, td").map { |cell| render_inline(cell).strip.gsub("|", "\\|") }
    end
    return if rows.empty?

    width = rows.map(&:length).max
    rows.each { |row| row.fill("", row.length...width) }
    separator = Array.new(width, "---")
    ([ rows.first, separator ] + rows.drop(1)).map { |row| "| #{row.join(" | ")} |" }.join("\n")
  end

  def render_inline(node)
    node.children.filter_map { |child| render_inline_node(child) }.join
  end

  def render_inline_node(node)
    return collapse_text(node.text) if node.text?
    return if node.comment? || skip_tag?(node)

    case node.name
    when "a"
      text = render_inline(node).strip
      href = node["href"].to_s
      return text if text.blank?
      href.present? ? "[#{text}](#{href})" : text
    when "strong", "b"
      text = render_inline(node).strip
      "**#{text}**" if text.present?
    when "em", "i"
      text = render_inline(node).strip
      "*#{text}*" if text.present?
    when "code"
      "`#{node.text}`"
    when "br"
      "\n"
    when "img"
      alt = node["alt"].to_s
      src = node["src"].to_s
      return if alt.blank? && src.blank?

      "![#{alt}](#{src})"
    else
      render_inline(node)
    end
  end

  def contains_block?(node)
    node.element_children.any? { |child| BLOCK_TAGS.include?(child.name) }
  end

  def skip_tag?(node)
    return false unless node.element?

    %w[script style noscript svg template dialog].include?(node.name)
  end

  def collapse_text(text)
    collapsed = text.gsub(/[ \t\f\r\n]+/, " ")
    collapsed.match?(/\S/) ? collapsed : nil
  end
end

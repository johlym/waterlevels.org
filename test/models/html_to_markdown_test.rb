require "test_helper"

class HtmlToMarkdownTest < ActiveSupport::TestCase
  test "converts headings, links, lists, and tables from main content" do
    html = <<~HTML
      <html>
        <head><title>Example Page</title></head>
        <body>
          <header><nav><a href="/">Home</a></nav></header>
          <section class="page-hero"><h1>Hero title</h1></section>
          <main id="main">
            <p>See the <a href="/faq">FAQ</a> and <strong>disclosures</strong>.</p>
            <ul><li>One</li><li>Two</li></ul>
            <table>
              <tr><th>Name</th><th>Value</th></tr>
              <tr><td>Stage</td><td>4.2</td></tr>
            </table>
            <script>alert("nope")</script>
          </main>
          <footer>Copyright</footer>
        </body>
      </html>
    HTML

    markdown = HtmlToMarkdown.convert(html)

    assert_includes markdown, "# Example Page"
    assert_includes markdown, "# Hero title"
    assert_includes markdown, "[FAQ](/faq)"
    assert_includes markdown, "**disclosures**"
    assert_includes markdown, "- One"
    assert_includes markdown, "| Name | Value |"
    assert_includes markdown, "| Stage | 4.2 |"
    refute_includes markdown, "Copyright"
    refute_includes markdown, "alert("
    refute_includes markdown, "Home"
  end

  test "estimates tokens as characters divided by four" do
    assert_equal 3, HtmlToMarkdown.token_count("abcdefghij")
    assert_equal 0, HtmlToMarkdown.token_count("")
  end
end

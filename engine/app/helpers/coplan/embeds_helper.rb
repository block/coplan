module CoPlan
  module EmbedsHelper
    def render_iframe_blocks(html, source)
      return html unless source.include?(ContentRegions::Iframe::PREFIX)

      lines = source.lines
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      # Only root-level, standalone paragraphs are content blocks. A marker
      # written in inline/fenced code, a quotation or a list stays literal.
      doc.children.select { |node| node.name == "p" }.each do |paragraph|
        pos = /\A(\d+):\d+-\1:\d+\z/.match(paragraph["data-sourcepos"].to_s)
        next unless pos

        block = ContentRegions::Iframe.call(lines[pos[1].to_i - 1].to_s.chomp)
        next unless block

        markup = if block.allowed?(host: request&.host)
          attrs = block.attributes
          width = attrs["width"].end_with?("%") ? attrs["width"] : "#{attrs['width']}px"
          tag.div(class: "iframe-content-block") do
            tag.iframe("", src: attrs["src"], title: attrs["title"], height: attrs["height"],
              style: "width: #{width}", sandbox: "allow-scripts allow-forms allow-same-origin", loading: "lazy",
              referrerpolicy: "strict-origin-when-cross-origin", allow: "camera 'none'; microphone 'none'; geolocation 'none'")
          end
        else
          tag.div("Embedded page unavailable. Check its URL, size, and administrator-approved domain.",
            class: "iframe-content-block__unavailable", role: "status")
        end
        paragraph.replace(Nokogiri::HTML::DocumentFragment.parse(markup))
      end
      doc.to_html
    end
  end
end

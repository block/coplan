module CoPlan
  module SummaryBlocksHelper
    SUMMARY_CLASS = "plan-summary".freeze
    SUMMARY_ID = "plan-summary".freeze

    # Wraps a summary block in section.plan-summary. The block was rendered
    # with its marker lines as thematic breaks (Split.with_summary_breaks);
    # the nodes between those two sibling breaks move into the
    # section and the breaks are dropped. `summary` holds the marker lines
    # in the coordinates of the rendered source, or nil for no block.
    #
    # Runs after sanitizing: raw HTML may write the wrapper's class or id, so
    # those are removed first and only this transform can create the card.
    # Nodes only move, and the markers never were text, so a selection inside
    # the card resolves to the same source as the canonical text extraction.
    def render_summary_block(html, summary)
      return html unless summary || html.include?(SUMMARY_CLASS)

      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css("[class~='#{SUMMARY_CLASS}']").each do |node|
        node.remove_attribute("id") if node["id"] == SUMMARY_ID
        node["class"] = node.classes.reject { |name| name == SUMMARY_CLASS }.join(" ")
        node.remove_attribute("class") if node["class"].empty?
      end

      opener = summary && summary_break(doc, summary.open_line)
      closer = summary && summary_break(doc, summary.close_line)
      if opener && closer && opener.parent == closer.parent &&
          opener.parent.children.index(opener) < closer.parent.children.index(closer)
        section = doc.document.create_element("section", class: SUMMARY_CLASS, id: summary_id(doc), "aria-label" => "Summary")
        opener.add_previous_sibling(section)
        node = opener.next_sibling
        until node == closer
          following = node.next_sibling
          section.add_child(node)
          node = following
        end
      end
      opener&.remove
      closer&.remove
      doc.to_html
    end

    private

    # Preserve existing heading and author fragments; the outline reads the
    # actual card id rather than assuming a fixed anchor.
    def summary_id(doc)
      ids = doc.css("[id]").map { |node| node["id"] }.to_set
      candidate = SUMMARY_ID
      suffix = 2
      while ids.include?(candidate)
        candidate = "#{SUMMARY_ID}-#{suffix}"
        suffix += 1
      end
      candidate
    end

    # Raw HTML can carry its own data-sourcepos, so a line claimed by more
    # than one break matches nothing.
    def summary_break(doc, line)
      pattern = /\A#{line}:\d+-#{line}:\d+\z/
      candidates = doc.css("hr[data-sourcepos]").select { |node| pattern.match?(node["data-sourcepos"].to_s) }
      candidates.first if candidates.one?
    end
  end
end

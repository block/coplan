module CoPlan
  # Lettered markers use the same source positions as numbered markers. Keep
  # every byte in place so selections, table targets, and edits share one map.
  module Markdown
    LETTERED_MARKER = /\A((?:[ \t]*>[ \t]?)*[ \t]*)([A-Z]{1,9}|[a-z]{1,9})\)(?=[ \t\r\n]|\z)/
    NUMBERED_MARKER = /\A(?:[ \t]*>[ \t]?)*[ \t]*(\d{1,9})[.)](?=[ \t\r\n]|\z)/
    TABLE_DELIMITER = /\A(?:[ \t]*>[ \t]?)*[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t\r\n]*\z/
    SOURCE_POSITION = /\A[1-9]\d*:[1-9]\d*-[1-9]\d*:\d+\z/
    # comrak's alerts know only GitHub's five types. A `[!SUMMARY]` marker
    # parses as a same-length `[!WARNING]` alert, and to_html renames the
    # alerts that start on those lines, so offsets never move.
    SUMMARY_MARKER = /\A((?:[ \t]*(?:>[ \t]?|(?:[-+*]|\d{1,9}[.)])[ \t]+))*[ \t]*>[ \t]?)\[!summary\]/i
    SUMMARY_STANDIN = "[!WARNING]".freeze

    def self.parse(source, **options)
      normalized, = normalize(source, options: options[:options])
      Commonmarker.parse(normalized, **options)
    end

    def self.to_html(source, **options)
      normalized, markers, summaries = normalize(source, options: options[:options])
      return Commonmarker.to_html(normalized, **options) if markers.empty? && summaries.empty?

      original_options = options[:options] || {}
      sourcepos = original_options.dig(:render, :sourcepos)
      options = options.merge(options: original_options.merge(render: (original_options[:render] || {}).merge(sourcepos: true)))
      doc = Nokogiri::HTML.fragment(Commonmarker.to_html(normalized, **options))
      lines = source.to_s.lines
      doc.css("ol[data-sourcepos]").reverse_each do |list|
        items = list.element_children
        next unless SOURCE_POSITION.match?(list["data-sourcepos"].to_s) && items.any? &&
          items.all? { |item| item.name == "li" && SOURCE_POSITION.match?(item["data-sourcepos"].to_s) }

        next unless items.any? { |item| markers.key?(item["data-sourcepos"].to_i) }

        groups = items.chunk do |item|
          markers[item["data-sourcepos"].to_i]&.fetch(:type) || "decimal"
        end
        groups.each do |type, items|
          type = nil if type == "decimal"
          replacement = Nokogiri::XML::Node.new("ol", doc)
          list.attribute_nodes.each { |attribute| replacement[attribute.name] = attribute.value }
          line = items.first["data-sourcepos"].to_i
          order = type ? markers.fetch(line)[:order] : (NUMBERED_MARKER.match(lines[line - 1].to_s)&.[](1)&.to_i || 1)
          replacement["type"] = type if type
          replacement.remove_attribute("start")
          replacement["start"] = order.to_s unless order == 1
          items.each { |item| replacement.add_child(item) }
          list.add_previous_sibling(replacement)
        end
        list.remove
      end
      summaries.each do |line, titled|
        alert = doc.css("div.markdown-alert-warning[data-sourcepos]").find { |node| node["data-sourcepos"].to_i == line }
        next unless alert

        alert["class"] = alert["class"].sub("markdown-alert-warning", "markdown-alert-summary")
        title = alert.element_children.first
        title.content = "Summary" if !titled && title&.[]("class") == "markdown-alert-title"
      end
      doc.css("[data-sourcepos]").each { |node| node.remove_attribute("data-sourcepos") } unless sourcepos
      doc.to_html
    end

    def self.normalize(source, options: nil)
      source = source.to_s
      lines = source.lines
      unless lines.any? { |line| LETTERED_MARKER.match?(line) }
        normalized, summaries = normalize_summaries(source, options)
        return [ normalized, {}, summaries ]
      end

      protected_lines = Set.new
      table_candidates = Set.new
      lines.each_with_index do |line, index|
        next unless line.include?("|") && TABLE_DELIMITER.match?(lines[index + 1].to_s)

        prefix = line[/\A(?:[ \t]*>[ \t]?)*[ \t]*/]
        index.upto(lines.length - 1) do |row|
          break if !lines[row].start_with?(prefix) || lines[row].delete_prefix(prefix).strip.empty?
          table_candidates.add(row)
        end
      end
      candidate = lines.each_with_index.map do |line, index|
        # A numeric marker can hide a pipe-less header or end a table's body.
        # Let the parser confirm these rows after opening their containers.
        next line if table_candidates.include?(index)

        line.sub(LETTERED_MARKER) { "#{Regexp.last_match(1)}#{'1'.rjust(Regexp.last_match(2).length, '0')})" }
      end.join
      collect_protected(Commonmarker.parse(source, options: options || {}), protected_lines, types: [ :table ])
      collect_protected(Commonmarker.parse(candidate, options: options || {}), protected_lines, types: %i[table code_block html_block])
      markers = {}
      normalized = lines.each_with_index.map do |line, index|
        match = LETTERED_MARKER.match(line)
        next line unless match && !protected_lines.include?(index + 1)

        letters = match[2]
        markers[index + 1] = { type: letters == letters.upcase ? "A" : "a",
          order: letters.upcase.each_byte.reduce(0) { |value, char| value * 26 + char - 64 } }
        line.sub(LETTERED_MARKER, "#{match[1]}#{'1'.rjust(letters.length, '0')})")
      end.join
      # Open lettered list containers before checking for summary alerts.
      normalized, summaries = normalize_summaries(normalized, options)
      [ normalized, markers, summaries ]
    end

    # Returns the source with each real summary marker swapped for its
    # stand-in, and { line => custom title? } for those lines. A candidate
    # comrak doesn't open an alert on (code, raw HTML, `>[!SUMMARY]`) keeps
    # its original text.
    def self.normalize_summaries(source, options)
      return [ source, {} ] unless source.match?(/\[!summary\]/i)

      lines = source.lines
      candidates = lines.each_index.select { |index| SUMMARY_MARKER.match?(lines[index]) }
      return [ source, {} ] if candidates.empty?

      swapped = lines.dup
      candidates.each { |index| swapped[index] = lines[index].sub(SUMMARY_MARKER) { "#{Regexp.last_match(1)}#{SUMMARY_STANDIN}" } }
      starts = Set.new
      collect_alert_starts(Commonmarker.parse(swapped.join, options: options || {}), starts)
      summaries = {}
      candidates.each do |index|
        next unless starts.include?(index + 1)

        summaries[index + 1] = lines[index].sub(SUMMARY_MARKER, "").strip.present?
        lines[index] = swapped[index]
      end
      [ lines.join, summaries ]
    end

    def self.collect_alert_starts(node, starts)
      starts.add(node.source_position[:start_line]) if node.type == :alert
      node.each { |child| collect_alert_starts(child, starts) }
    end
    private_class_method :normalize_summaries, :collect_alert_starts

    def self.collect_protected(node, lines, types:)
      if types.include?(node.type)
        position = node.source_position
        lines.merge(position[:start_line]..position[:end_line])
      else
        node.each { |child| collect_protected(child, lines, types:) }
      end
    end
    private_class_method :collect_protected
  end
end

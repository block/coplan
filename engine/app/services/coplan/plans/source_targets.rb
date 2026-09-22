require "strscan"

module CoPlan
  module Plans
    # Render-time source map. Ranges are Ruby character offsets (the same
    # units as TransformRange), never DOM text offsets or label occurrences.
    # Tokens are signed and content-bound so cached HTML is safe to reuse,
    # but a selection from an older document cannot silently move elsewhere.
    class SourceTargets
      KINDS = %w[table_cell mermaid_node mermaid_edge mermaid_diagram].freeze

      def self.verifier
        Rails.application.message_verifier("coplan-source-target-v1")
      end

      def self.resolve(token, content)
        data = verifier.verified(token, purpose: "comment")
        return unless data.is_a?(Hash) && data["digest"] == Digest::SHA256.hexdigest(content)
        return unless KINDS.include?(data["kind"])

        s, e = data.values_at("start", "end")
        return unless s.is_a?(Integer) && e.is_a?(Integer) && s >= 0 && e > s && e <= content.length

        data
      end

      def initialize(content)
        @content = content.to_s
        @lines = @content.lines
        @offsets = [ 0 ]
        @lines.each { |line| @offsets << @offsets.last + line.length }
        @digest = Digest::SHA256.hexdigest(@content)
        # Raw HTML may contain data-sourcepos supplied by the author. Only
        # positions produced by the Markdown AST can become signed targets.
        @positions = Hash.new { |hash, key| hash[key] = Set.new }
        collect_positions(Commonmarker.parse(@content, options: { extension: MarkdownHelper::EXTENSION_OPTIONS }))
      end

      def annotate(doc)
        rows = {}
        doc.css("table").each do |table|
          table.css("tr").each_with_index { |row, index| rows[row] = index + 1 }
        end
        cells = doc.css("th[data-sourcepos], td[data-sourcepos]")
        cell_counts = cells.group_by { |cell| cell["data-sourcepos"] }
        cells.each do |cell|
          next unless @positions[:table_cell].include?(cell["data-sourcepos"]) && cell_counts[cell["data-sourcepos"]].one?
          range = source_range(cell["data-sourcepos"])
          next unless range
          s, e = range
          # Commonmarker reports an empty span for `||`. Include its closing
          # pipe so filling/deleting this cell conflicts with the anchor.
          if @content[s...e].to_s.strip.empty?
            # Both pipes fence the empty cell: inserting content between
            # them must invalidate the thread, not move it onto a neighbor.
            next unless @content[s - 1] == "|" && @content[e] == "|"
            s -= 1
            e += 1
          end
          next unless e > s

          row = cell.parent
          label = "Row #{rows.fetch(row)}, column #{row.element_children.index(cell) + 1}"
          cell["data-source-target"] = target("table_cell", s, e, label).to_json
          cell["tabindex"] = "0"
          cell["data-action"] = "click->coplan--source-comments#select keydown->coplan--source-comments#key"
        end

        pres = doc.css('pre[lang="mermaid"][data-sourcepos]')
        pre_counts = pres.group_by { |pre| pre["data-sourcepos"] }
        pres.each do |pre|
          next unless @positions[:code_block].include?(pre["data-sourcepos"]) && pre_counts[pre["data-sourcepos"]].one?
          range = source_range(pre["data-sourcepos"])
          next unless range
          line = pre["data-sourcepos"].to_i
          source = pre.at_css("code")&.text
          offset = @offsets[line]
          # Nested/indented fences can have prefixes stripped by Commonmark.
          # Only map a source that is byte-for-byte the fenced body.
          next unless source && offset && @content[offset, source.length] == source

          targets = flowchart_targets(source, offset) || { nodes: {}, edges: [] }
          targets[:diagram] = target("mermaid_diagram", *range, "Entire diagram")
          pre["data-source-targets"] = targets.to_json
        end
        doc
      end

      # Used after OT: a surviving range must still describe a selectable
      # element, rather than syntax that an edit elsewhere turned into prose.
      def ranges
        html = Commonmarker.to_html(@content, options: { extension: MarkdownHelper::EXTENSION_OPTIONS,
          render: { sourcepos: true } }, plugins: { syntax_highlighter: nil })
        doc = annotate(Nokogiri::HTML.fragment(html))
        targets = doc.css("[data-source-target]").map { |node| JSON.parse(node["data-source-target"]) }
        doc.css("[data-source-targets]").each do |node|
          map = JSON.parse(node["data-source-targets"])
          targets.concat(map["nodes"].values + map["edges"] + [ map["diagram"] ].compact)
        end
        targets.map { |target| target.values_at("kind", "start", "end") }.to_set
      end

      private

      def collect_positions(node)
        if %i[table_cell code_block].include?(node.type)
          p = node.source_position
          @positions[node.type] << "#{p[:start_line]}:#{p[:start_column]}-#{p[:end_line]}:#{p[:end_column]}"
        end
        node.each { |child| collect_positions(child) }
      end

      def source_range(position)
        match = /\A(\d+):(\d+)-(\d+):(\d+)\z/.match(position)
        return unless match
        sl, sc, el, ec = match.captures.map(&:to_i)
        return unless sl.positive? && el.positive? && sc.positive? && @lines[sl - 1] && @lines[el - 1]

        # Commonmarker columns are bytes, including the inclusive end.
        before = @lines[sl - 1].byteslice(0, sc - 1)
        through = @lines[el - 1].byteslice(0, ec)
        return unless before&.valid_encoding? && through&.valid_encoding?
        [ @offsets[sl - 1] + before.length, @offsets[el - 1] + through.length ]
      end

      def target(kind, s, e, label)
        data = { "digest" => @digest, "kind" => kind, "start" => s, "end" => e, "label" => label }
        data.merge("text" => @content[s...e], "token" => self.class.verifier.generate(data, purpose: "comment"))
      end

      # Deliberately bounded grammar. If any statement is not understood,
      # the diagram remains viewable/expandable but has no element targets.
      # We never guess which SVG edge a partially parsed statement meant.
      # Supported: ordinary single-line nodes, chains, pipe/text edge labels,
      # semicolons, subgraphs, and styling. Mermaid's own parsed graph is
      # additionally checked in the browser before binding any SVG targets.
      NODE = /[A-Za-z_][A-Za-z0-9_]*(?:-[A-Za-z0-9_]+)*/
      SHAPES = { "(((" => ")))", "((" => "))", "([" => "])", "[[" => "]]", "[(" => ")]", "{{" => "}}", "[" => "]", "(" => ")", "{" => "}", ">" => "]" }.freeze
      LINK = /(?:<-->|<==>|<-\.->|-->|---|==>|===|-\.->|-\.-|--o|--x|o--o|x--x)/

      def flowchart_targets(source, offset)
        scanner = StringScanner.new(source)
        scanner.skip(/\s*/)
        return unless scanner.scan(/(?:flowchart|graph)\s+(?:TB|TD|BT|LR|RL)\b/)
        nodes = {}
        declarations = Hash.new(0)
        edges = []
        until scanner.eos?
          scanner.skip(/[\s;]*/)
          break if scanner.eos?
          if scanner.scan(/(?:%%[^\n]*|(?:subgraph|direction|classDef|class|style|linkStyle|click)\s+[^\n]*|end(?=\s|;|\z))/)
            next
          end
          left = read_node(scanner, source, offset, nodes, declarations)
          return unless left
          loop do
            scanner.skip(/[ \t]*/)
            break if scanner.eos? || scanner.check(/[\n;]|%%/)
            link = scanner.scan(LINK)
            unless link
              # Mermaid's `A -- label --> B` spelling.
              return unless scanner.scan(/--[ \t]+[^\n;|]+?[ \t]+-->/)
            end
            scanner.skip(/[ \t]*/)
            if scanner.scan(/\|/)
              return unless scanner.scan(/[^\n|]*\|/)
              scanner.skip(/[ \t]*/)
            end
            right = read_node(scanner, source, offset, nodes, declarations)
            return unless right
            edges << target("mermaid_edge", left[:start], right[:end], "Connection #{left[:id]} → #{right[:id]}")
              .merge("from" => left[:id], "to" => right[:id])
            left = right
          end
        end
        # More than one explicit declaration is ambiguous to a reviewer;
        # leave that node unselectable rather than choosing one arbitrarily.
        nodes.reject! { |id, _| declarations[id] > 1 }
        { nodes: nodes, edges: edges }
      end

      def read_node(scanner, source, offset, nodes, declarations)
        start = offset + source.byteslice(0, scanner.pos).length
        id = scanner.scan(NODE)
        return unless id
        # New shapes use the same stable node ID as classic flowcharts.
        # Bound single-line attributes; quoted braces stay inside the label.
        attributes = scanner.scan(/@\{(?:[^"{}\n]|"(?:\\.|[^"\\\n])*")*\}/)
        return if !attributes && scanner.check(/@/)
        shape = SHAPES.keys.find { |open| scanner.peek(open.bytesize) == open }
        if shape
          scanner.pos += shape.bytesize
          close = SHAPES.fetch(shape)
          if scanner.scan(/"/)
            return unless scanner.scan(/[^"\n]*"/)
            return unless scanner.scan(Regexp.new(Regexp.escape(close)))
          else
            return unless scanner.scan(Regexp.new("[^\\n]*?#{Regexp.escape(close)}"))
          end
          declarations[id] += 1
        end
        declarations[id] += 1 if attributes
        finish = offset + source.byteslice(0, scanner.pos).length
        nodes[id] = target("mermaid_node", start, finish, "Node #{id}").merge("id" => id) if shape || attributes || !nodes.key?(id)
        scanner.scan(/:::[A-Za-z_][A-Za-z0-9_-]*/)
        { id: id, start: start, end: finish }
      end
    end
  end
end

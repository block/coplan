module CoPlan
  module WritingProvenanceHelper
    def writing_provenance_summary(plan)
      summary = plan.writing_provenance_summary
      summary if summary.is_a?(Hash) && summary["revision"] == plan.current_revision
    end

    def writing_provenance_label(summary)
      return "Writing origin unknown" unless summary && summary["total"].positive?
      total, counts = summary.values_at("total", "counts")
      return "Entirely human written" if counts["human"] == total
      return "Entirely AI written" if counts["ai"] == total
      return "Writing origin unknown" if counts["unknown"] == total
      return "Mostly human written" if counts["human"] > total / 2.0
      if counts["ai"] > total / 2.0
        harnesses = summary.fetch("contributors").select { |source| source["kind"] == "ai" && source["harness"].present? }.group_by { |source| source["harness"] }
        dominant = harnesses.values.find { |sources| sources.sum { |source| source["characters"] } > total / 2.0 }
        return "Mostly #{dominant.first.fetch('harness_name')} written" if dominant
        return "Mostly AI written"
      end
      counts["unknown"] > total / 2.0 ? "Writing origin mostly unknown" : "Mixed writing origins"
    end

    def writing_provenance_icon(summary)
      total = summary&.fetch("total", 0).to_i
      counts = summary&.fetch("counts", {}) || {}
      kind = %w[human ai unknown].find { |key| counts.fetch(key, 0) > total / 2.0 }
      # Icons mirror the quiet person/robot pair used for source attribution.
      paths = case kind
      when "human"
        '<circle cx="12" cy="8" r="4"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/>'
      when "ai"
        '<rect x="4" y="7" width="16" height="13" rx="3"/><path d="M12 3v4M2 11v5M22 11v5M8 16h8"/><circle cx="9" cy="12" r=".5"/><circle cx="15" cy="12" r=".5"/>'
      else
        '<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-1 .4-1 1-1 1.7M12 17h.01"/>'
      end
      content_tag(:svg, paths.html_safe, width: 16, height: 16, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": 1.6, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true)
    end

    def writing_provenance_rows(summary)
      contributors = summary.fetch("contributors")
      missing_names = contributors.select { |source| source["kind"] == "human" && source["user_name"].blank? }.filter_map { |source| source["user_id"] }
      names = missing_names.empty? ? {} : CoPlan::User.where(id: missing_names).pluck(:id, :name).to_h
      rows, accounted = {}, Hash.new(0)
      contributors.each do |source|
        kind, count = source.values_at("kind", "characters")
        next unless %w[human ai].include?(kind) && count.positive?
        label = if kind == "human"
          source["user_name"].presence || names[source["user_id"]].presence || "Human written"
        else
          source["agent_name"].presence || source["harness_name"].presence || "AI written"
        end
        identity = kind == "human" ? source["user_id"].presence || label : [ source["harness"], label ]
        row = (rows[[ kind, identity ]] ||= { kind: kind, label: label, characters: 0, details: [] })
        row[:characters] += count
        row[:details] |= [ source["harness_name"], source["model"], source["harness_version"] ].compact_blank if kind == "ai"
        accounted[kind] += count
      end
      result = rows.values.sort_by { |row| [ row[:kind] == "human" ? 0 : 1, -row[:characters], row[:label] ] }
      { "human" => "Human written", "ai" => "AI written" }.each do |kind, label|
        remaining = summary.fetch("counts").fetch(kind) - accounted[kind]
        result << { kind: kind, label: label, characters: remaining, details: [] } if remaining.positive?
      end
      unknown = summary.fetch("counts").fetch("unknown")
      result << { kind: "unknown", label: "Unknown", characters: unknown, details: [] } if unknown.positive?
      result
    end

    def writing_provenance_percent(count, total)
      return "0%" if total.zero? || count.zero?
      return "100%" if count == total
      percent = count.fdiv(total) * 100
      percent < 1 ? "<1%" : "#{[ percent.round, 99 ].min}%"
    end
  end
end

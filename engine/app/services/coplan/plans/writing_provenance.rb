require "diff/lcs"

module CoPlan
  module Plans
    # Immutable, run-length encoded source attribution. Historical human saves
    # from uninstrumented writers use the rollout's human-input assumption.
    # Actor identity is separate from input evidence on subsequent writes.
    class WritingProvenance
      FORMAT = 1
      HISTORY_POLICY = 3
      # Bearer-only agent identity landed in #178 on August 17. Before then,
      # host-authenticated API agents were also saved with actor_type "human".
      RELIABLE_HUMAN_ATTRIBUTION_FROM = Time.utc(2026, 8, 18).freeze
      KINDS = %w[human ai unknown].freeze
      MAX_DIFF_CELLS = 1_000_000
      MAX_INPUT_RUNS = 4096
      UNKNOWN = "unknown".freeze
      MAX_INSPECTION_CHARACTERS = 250_000
      MAX_INSPECTION_RUNS = 10_000
      class InspectionLimit < StandardError; end

      def self.agent_write?(version)
        version.actor_type.in?(%w[local_agent cloud_persona]) ||
          (version.actor_type == "human" && (version.api_token_id.present? || version.agent_name.present?))
      end

      def self.ambiguous_legacy?(version)
        version.actor_type == "human" && version.created_at && version.created_at < RELIABLE_HUMAN_ATTRIBUTION_FROM &&
          !agent_write?(version) && version.writing_provenance.to_h.dig("write_source", "kind") != "ai"
      end

      def self.call(version:, previous: nil, historical_human: false)
        new(version:, previous:, historical_human:).call
      end

      def self.rendered_sources(version)
        if version.content_markdown.length > MAX_INSPECTION_CHARACTERS || version.writing_provenance.fetch("runs").length > MAX_INSPECTION_RUNS
          raise InspectionLimit, "This document is too large to inspect. Writing percentages are still available."
        end
        fingerprint = Digest::SHA256.hexdigest(version.writing_provenance.to_json)
        Rails.cache.fetch([ "coplan/rendered-writing-v3", version.id, fingerprint ], expires_in: 12.hours) do
          build_rendered_sources(version)
        end
      end

      def self.build_rendered_sources(version)
        text, _, spans = MarkdownTextExtractor.call(version.content_markdown, exclude_nonprose: true, source_spans: true)
        snapshot = version.writing_provenance
        offset = 0
        intervals = snapshot.fetch("runs").map { |length, key| offset += length; [ offset, key ] }
        result, runs = +"", []
        text.each_char.with_index do |char, index|
          next if char.match?(/[[:space:]]/)
          from, to = spans.fetch(index)
          key = if from >= 0 && to > from
            first = intervals.bsearch_index { |stop, _| stop > from }
            if first
              keys = []
              first.upto(intervals.length - 1) do |i|
                stop, source = intervals[i]
                keys << source
                break if stop >= to
              end
              keys.uniq.one? ? keys.first : nil
            end
          end
          result << char
          append(runs, char.encode(Encoding::UTF_16LE).bytesize / 2, key)
        end
        { text: result, runs: runs, sources: snapshot.fetch("sources") }
      end

      def initialize(version:, previous:, historical_human: false)
        @version, @previous = version, previous
        @historical_human = historical_human
      end

      def call
        content = @version.content_markdown
        old = @previous&.content_markdown.to_s
        snapshot = @previous&.writing_provenance.to_h
        valid = snapshot["format"] == FORMAT && snapshot["sha256"] == Digest::SHA256.hexdigest(old)
        sources = valid ? snapshot.fetch("sources").deep_dup : {}
        sources[UNKNOWN] = { "kind" => UNKNOWN }
        prior_runs = valid ? snapshot.fetch("runs") : [ [ old.length, UNKNOWN ] ]
        origin = { "origin_revision" => @version.revision, "origin_at" => (@version.created_at || Time.current).iso8601,
          "user_name" => @version.actor_user&.name }.compact
        identity = source_identity.merge(origin)
        source_key = Digest::SHA256.hexdigest(identity.sort.to_h.to_json).first(24)
        sources[source_key] = identity
        unknown_identity = { "kind" => UNKNOWN, "user_id" => @version.actor_id }.compact.merge(origin)
        unknown_key = Digest::SHA256.hexdigest(unknown_identity.sort.to_h.to_json).first(24)
        sources[unknown_key] = unknown_identity
        input = self.class.input_runs(@version.input_sources, content)
        insertions = if identity["kind"] == "human" && input
          input.map { |length, kind| [ length, kind == "human" ? source_key : unknown_key ] }
        else
          [ [ content.length, identity["kind"] == "ai" ? source_key : unknown_key ] ]
        end
        runs = self.class.remap(old, content, prior_runs, insertions, fallback_source: @historical_human ? source_key : UNKNOWN)
        runs, removed_lines = WritingProvenanceMoves.call(before: old, after: content, prior_runs: prior_runs, runs: runs,
          removed_lines: valid ? snapshot.fetch("removed_lines", []) : [])
        retained = (runs + removed_lines.flat_map { |_, line_runs| line_runs || [] }).map(&:last).to_set
        sources.select! { |key, _| retained.include?(key) }
        summary = summarize(content, runs, sources)
        result = { "format" => FORMAT, "sha256" => Digest::SHA256.hexdigest(content), "write_source" => identity,
          "runs" => runs, "sources" => sources, "summary" => summary }
        result["removed_lines"] = removed_lines if removed_lines.any?
        # A new save cannot certify old attribution that it merely retained.
        result["history_policy"] = HISTORY_POLICY if @previous.nil? || snapshot["history_policy"] == HISTORY_POLICY
        # Preserve the cutover assumption on replay, including bounded large
        # rewrites. Instrumented writes always have a snapshot, even when their
        # input evidence is missing and therefore Unknown.
        result["historical_human"] = true if @historical_human
        result
      end

      # The editor uses UTF-16 offsets; Ruby uses Unicode codepoints. Reject
      # malformed evidence, including boundaries inside surrogate pairs.
      def self.input_runs(payload, content)
        return unless payload.is_a?(Hash)
        raw = payload["runs"] || payload[:runs]
        return unless raw.is_a?(Array) && raw.length <= MAX_INPUT_RUNS
        return unless raw.all? { |run| run.is_a?(Array) && run.length == 2 && run[0].is_a?(Integer) && run[0].positive? && %w[human unknown].include?(run[1]) }
        wanted = raw.map(&:first).each_with_object([ 0 ]) { |length, bounds| bounds << bounds.last + length }
        positions = { 0 => 0 }
        units = 0
        boundaries = wanted.to_set
        content.each_codepoint.with_index do |codepoint, index|
          units += codepoint > 0xffff ? 2 : 1
          positions[units] = index + 1 if boundaries.include?(units)
        end
        return unless wanted.last == units && wanted.all? { |offset| positions.key?(offset) }
        raw.each_with_index.map { |(_, kind), i| [ positions.fetch(wanted[i + 1]) - positions.fetch(wanted[i]), kind ] }
      end

      def self.append(runs, length, source)
        return if length <= 0
        if runs.any? && runs.last.last == source
          runs.last[0] += length
        else
          runs << [ length, source ]
        end
      end

      def self.slice(runs, from, to)
        result, cursor = [], 0
        runs.each do |length, source|
          stop = cursor + length
          append(result, [ stop, to ].min - [ cursor, from ].max, source)
          cursor = stop
          break if cursor >= to
        end
        result
      end

      # Diff lines first, then refine changed hunks. A typo must not transfer
      # an entire paragraph. Bound pathological diffs and fail toward unknown.
      def self.remap(before, after, prior_runs, insertion_runs, fallback_source: UNKNOWN)
        return prior_runs.map(&:dup) if before == after
        return insertion_runs.map(&:dup) if before.empty?
        old_lines, new_lines = before.lines, after.lines
        prefix = 0
        prefix += 1 while prefix < old_lines.length && prefix < new_lines.length && old_lines[prefix] == new_lines[prefix]
        suffix = 0
        suffix += 1 while suffix < old_lines.length - prefix && suffix < new_lines.length - prefix && old_lines[-suffix - 1] == new_lines[-suffix - 1]
        if prefix.positive? || suffix.positive?
          start = old_lines.first(prefix).sum(&:length)
          tail = old_lines.last(suffix).sum(&:length)
          middle = remap(old_lines[prefix...old_lines.length - suffix].join, new_lines[prefix...new_lines.length - suffix].join,
            slice(prior_runs, start, before.length - tail), slice(insertion_runs, start, after.length - tail), fallback_source: fallback_source)
          result = []
          (slice(prior_runs, 0, start) + middle + slice(prior_runs, before.length - tail, before.length)).each { |n, key| append(result, n, key) }
          return result
        end
        if old_lines.length * new_lines.length > MAX_DIFF_CELLS
          return [ [ after.length, fallback_source ] ].reject { |length, _| length.zero? }
        end
        result, old_offset, new_offset = [], 0, 0
        old_chunk, new_chunk = +"", +""
        flush = lambda do
          refined = refine(old_chunk, new_chunk, slice(prior_runs, old_offset, old_offset + old_chunk.length),
            slice(insertion_runs, new_offset, new_offset + new_chunk.length), fallback_source: fallback_source)
          refined.each { |n, key| append(result, n, key) }
          old_offset += old_chunk.length
          new_offset += new_chunk.length
          old_chunk.clear
          new_chunk.clear
        end
        Diff::LCS.sdiff(old_lines, new_lines).each do |change|
          if change.action == "="
            flush.call
            slice(prior_runs, old_offset, old_offset + change.old_element.length).each { |n, key| append(result, n, key) }
            old_offset += change.old_element.length
            new_offset += change.new_element.length
          else
            old_chunk << change.old_element unless change.action == "+"
            new_chunk << change.new_element unless change.action == "-"
          end
        end
        flush.call
        result
      end

      def self.refine(before, after, prior_runs, insertion_runs, fallback_source: UNKNOWN)
        return [] if after.empty?
        return insertion_runs if before.empty?
        old, fresh = before.chars, after.chars
        prefix = 0
        prefix += 1 while prefix < old.length && prefix < fresh.length && old[prefix] == fresh[prefix]
        suffix = 0
        suffix += 1 while suffix < old.length - prefix && suffix < fresh.length - prefix && old[-suffix - 1] == fresh[-suffix - 1]
        old_middle = old[prefix...old.length - suffix]
        new_middle = fresh[prefix...fresh.length - suffix]
        result = slice(prior_runs, 0, prefix)
        if old_middle.empty?
          slice(insertion_runs, prefix, fresh.length - suffix).each { |n, key| append(result, n, key) }
        elsif old_middle.length * new_middle.length > MAX_DIFF_CELLS
          append(result, new_middle.length, fallback_source)
        elsif new_middle.any?
          old_sources = slice(prior_runs, prefix, old.length - suffix).flat_map { |n, key| Array.new(n, key) }
          new_sources = slice(insertion_runs, prefix, fresh.length - suffix).flat_map { |n, key| Array.new(n, key) }
          Diff::LCS.sdiff(old_middle, new_middle).each do |change|
            if change.action == "="
              append(result, 1, old_sources.fetch(change.old_position))
            elsif change.action != "-"
              append(result, 1, new_sources.fetch(change.new_position))
            end
          end
        end
        slice(prior_runs, old.length - suffix, old.length).each { |n, key| append(result, n, key) }
        result
      end

      private

      def source_identity
        return @version.writing_identity if @version.writing_identity.is_a?(Hash)
        return { "kind" => UNKNOWN } unless @version.actor_type.in?(%w[human local_agent cloud_persona])
        return { "kind" => "human", "user_id" => @version.actor_id } unless self.class.agent_write?(@version)
        metadata = @version.api_token&.metadata.to_h
        harness = metadata["harness"].presence
        key = harness && AgentHarness.canonical_key(harness)
        { "kind" => "ai", "user_id" => @version.actor_id,
          "agent_name" => @version.agent_name.presence || @version.api_token&.agent_name, "harness" => key,
          "harness_name" => key && AgentHarness.default_display_name(key, harness),
          "harness_version" => metadata["harness_version"], "model" => metadata["model"].presence || @version.ai_model }.compact
      end

      def summarize(content, runs, sources)
        counts = KINDS.index_with { 0 }
        contributions, offset = Hash.new(0), 0
        runs.each do |length, source|
          count = content[offset, length].gsub(/[[:space:]]/, "").length
          counts[sources.fetch(source).fetch("kind")] += count
          contributions[source] += count
          offset += length
        end
        grouped = {}
        contributions.each do |key, count|
          next unless count.positive?
          identity = sources.fetch(key).except("origin_revision", "origin_at")
          group = (grouped[identity] ||= identity.merge("characters" => 0))
          group["characters"] += count
        end
        total = counts.values.sum
        { "revision" => @version.revision, "method" => "retained_markdown_v1",
          "unit" => "non_whitespace_markdown_characters", "total" => total,
          "counts" => counts, "shares" => counts.transform_values { |count| total.zero? ? 0 : count.fdiv(total) },
          "contributors" => grouped.values.map { |source|
            source.merge("share" => total.zero? ? 0 : source["characters"].fdiv(total))
          }.sort_by { |source| -source["characters"] } }
      end
    end
  end
end

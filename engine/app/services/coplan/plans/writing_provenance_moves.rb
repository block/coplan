module CoPlan
  module Plans
    # Exact lines carry their original character sources when reordered. Keep
    # bounded deleted-line evidence so autosaving a cut does not erase it before
    # the paste. Conflicting origins for identical lines are never guessed.
    class WritingProvenanceMoves
      MAX_CHARACTERS = 100_000
      MAX_LINES = 2048
      MAX_RUNS = 4096

      def self.call(before:, after:, prior_runs:, runs:, removed_lines:, fresh_source: nil)
        new.call(before: before, after: after, prior_runs: prior_runs, runs: runs, removed_lines: removed_lines, fresh_source: fresh_source)
      end

      def call(before:, after:, prior_runs:, runs:, removed_lines:, fresh_source:)
        @lines = {}
        current_lines = Set.new
        @characters = @run_count = 0
        each_line(before, prior_runs) do |text, line_runs, _|
          current_lines << text
          remember(text, line_runs)
        end
        removed_lines.each { |text, line_runs| remember(text, line_runs) }

        result = []
        present = Set.new
        each_line(after, runs) do |text, line_runs, ending_runs|
          present << text
          restored = @lines[text]
          if restored && fresh_source && !current_lines.include?(text)
            restored = retain_fresh_input(line_runs, restored, fresh_source)
          end
          (restored || line_runs).each { |length, source| WritingProvenance.append(result, length, source) }
          ending_runs.each { |length, source| WritingProvenance.append(result, length, source) }
        end
        [ result, @lines.reject { |text, _| present.include?(text) }.to_a ]
      end

      private

      # Recreating an old line can be a new action: typing an old sentence or
      # checking a task again. Archived text cannot erase that observed input.
      def retain_fresh_input(runs, archived, fresh_source)
        result = []
        index = offset = 0
        runs.each do |length, source|
          while length.positive?
            old_length, old_source = archived.fetch(index)
            count = [ length, old_length - offset ].min
            WritingProvenance.append(result, count, source == fresh_source ? source : old_source)
            length -= count
            offset += count
            if offset == old_length
              index += 1
              offset = 0
            end
          end
        end
        result
      end

      def remember(text, runs)
        return unless text.match?(/[[:alnum:]]/)
        if @lines.key?(text)
          @lines[text] = nil unless @lines[text] == runs
        elsif @lines.size < MAX_LINES && @characters + text.length <= MAX_CHARACTERS && @run_count + runs.to_a.size <= MAX_RUNS
          @lines[text] = runs
          @characters += text.length
          @run_count += runs.to_a.size
        end
      end

      # Walk the run stream once; slicing from its start for every line would
      # multiply work on documents with many lines and many small edits.
      def each_line(content, runs)
        index = offset = 0
        take = lambda do |length|
          result = []
          while length.positive?
            run_length, source = runs.fetch(index)
            count = [ length, run_length - offset ].min
            WritingProvenance.append(result, count, source)
            length -= count
            offset += count
            if offset == run_length
              index += 1
              offset = 0
            end
          end
          result
        end
        content.each_line do |line|
          text = line.delete_suffix("\n")
          line_runs = take.call(text.length)
          yield text, line_runs, take.call(line.length - text.length)
        end
      end
    end
  end
end

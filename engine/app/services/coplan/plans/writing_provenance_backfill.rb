module CoPlan
  module Plans
    # Persist progress and a worker lease on the document. Compute outside the
    # plan lock; check ownership again before committing each checkpoint.
    class WritingProvenanceBackfill
      LEASE = 5.minutes
      BATCH_SIZE = 20
      BATCH_SECONDS = 3

      def self.claim(plan, restart: false)
        plan.with_lock do
          state = plan.writing_provenance_backfill.to_h.deep_dup
          state = state.slice("legacy_revision").merge("revision" => 0) if restart
          state["legacy_revision"] ||= 0
          state["revision"] ||= 0
          return if state["token"] && Time.iso8601(state.fetch("expires_at")) > Time.current
          if state["revision"].positive?
            checkpoint = plan.plan_versions.find_by(revision: state["revision"])
            snapshot = checkpoint&.writing_provenance.to_h
            state["revision"] = 0 unless snapshot && snapshot["format"] == WritingProvenance::FORMAT && snapshot["sha256"] == checkpoint.content_sha256
          end
          return if !restart && state["revision"] >= plan.current_revision && plan.writing_provenance_summary&.dig("revision") == plan.current_revision
          token = SecureRandom.uuid
          state.merge!("token" => token, "expires_at" => LEASE.from_now.iso8601)
          plan.update_columns(writing_provenance_backfill: state)
          token
        end
      end

      def self.release(plan, token)
        plan.with_lock do
          state = plan.writing_provenance_backfill.to_h
          plan.update_columns(writing_provenance_backfill: state.except("token", "expires_at")) if state["token"] == token
        end
      end

      def self.pending?(plan)
        state = plan.writing_provenance_backfill
        state ? state.fetch("revision", 0) < plan.current_revision : plan.writing_provenance_summary.nil?
      end

      def self.call(plan:, token:)
        new(plan, token).call
      end

      def initialize(plan, token)
        @plan, @token = plan, token
      end

      # Each saved version is a checkpoint. A crash between saving progress
      # and scheduling the next batch is recovered by the coordinator.
      def call
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        BATCH_SIZE.times do
          state = @plan.reload.writing_provenance_backfill.to_h
          return false unless state["token"] == @token
          revision = state.fetch("revision")
          version = @plan.plan_versions.where("revision > ?", revision).reorder(:revision).includes(:api_token, :actor_user).first
          return complete(revision) unless version
          previous = @plan.plan_versions.find_by(revision: revision) if revision.positive?
          restore_input(version, state.fetch("legacy_revision"))
          legacy = version.revision <= state.fetch("legacy_revision") && version.actor_type == "human" && version.writing_identity&.dig("kind") != "ai"
          snapshot = WritingProvenance.call(version: version, previous: previous, historical_human: legacy)
          persisted = @plan.with_lock do
            current = @plan.writing_provenance_backfill.to_h
            next false unless current["token"] == @token && current["revision"] == revision
            version.update_columns(writing_provenance: snapshot)
            @plan.update_columns(writing_provenance_backfill: current.merge("revision" => version.revision, "expires_at" => LEASE.from_now.iso8601))
            true
          end
          return false unless persisted
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= BATCH_SECONDS
        end
        true
      end

      private

      def restore_input(version, legacy_revision)
        existing = version.writing_provenance.to_h
        version.writing_identity = existing["write_source"]
        return unless version.actor_type == "human" && existing.dig("write_source", "kind") != "ai"
        if version.revision <= legacy_revision
          version.input_sources = { "runs" => [ [ version.content_markdown.encode(Encoding::UTF_16LE).bytesize / 2, "human" ] ] }
        elsif existing["format"] == WritingProvenance::FORMAT
          offset = 0
          version.input_sources = { "runs" => existing.fetch("runs").map { |length, key|
            text = version.content_markdown[offset, length]
            offset += length
            kind = existing.fetch("sources").fetch(key).fetch("kind") == "human" ? "human" : "unknown"
            [ text.encode(Encoding::UTF_16LE).bytesize / 2, kind ]
          } }
        end
      end

      def complete(revision)
        updated = @plan.with_lock do
          state = @plan.writing_provenance_backfill.to_h
          next false unless state["token"] == @token && state["revision"] == revision
          # A save can commit between the version query and taking this lock.
          next :continue if @plan.current_revision > revision
          version = @plan.current_plan_version
          @plan.update_columns(writing_provenance_summary: version&.writing_provenance&.fetch("summary"),
            writing_provenance_backfill: state.except("token", "expires_at"))
          true
        end
        return true if updated == :continue
        Broadcaster.replace_to(@plan, target: "writing-provenance", partial: "coplan/plans/writing_provenance", locals: { plan: @plan }) if updated
        false
      end
    end
  end
end

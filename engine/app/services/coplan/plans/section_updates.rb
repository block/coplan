module CoPlan
  module Plans
    # Attribute each signposted section to the most recent version that
    # actually changed it. A later edit elsewhere must not take credit.
    class SectionUpdates
      def self.call(plan:, keys:, since_revision:)
        new(plan: plan, keys: keys, since_revision: since_revision).call
      end

      def initialize(plan:, keys:, since_revision:)
        @plan = plan
        @keys = keys
        @since_revision = since_revision
      end

      def call
        return {} if @keys.empty?

        pending = @keys.to_set
        updates = {}
        newer_version = nil
        newer_sections = nil
        versions = @plan.plan_versions.where(revision: @since_revision..@plan.current_revision)
          .includes(:actor_user)

        # Walk backwards and stop as soon as every changed section has an
        # author. Batching avoids loading an entire long version history.
        loop do
          batch = versions.reorder(revision: :desc).limit(20).to_a
          break if batch.empty?

          batch.each do |version|
            sections = ChangedSections.sections(version.content_markdown)
            if newer_version
              pending.to_a.each do |key|
                next if sections.key?(key) && sections[key] == newer_sections[key]

                updates[key] = newer_version
                pending.delete(key)
              end
              return updates if pending.empty?
            end
            newer_version = version
            newer_sections = sections
          end
          versions = versions.where("revision < ?", batch.last.revision)
        end
        updates
      end
    end
  end
end

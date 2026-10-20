module CoPlan
  module Plans
    class CreateHumanDraft
      class InvalidKey < StandardError; end
      class PlacementFailed < StandardError; end
      KEY_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      def self.call(user:, title:, content:, tags:, creation_key: nil, plan_type: nil, folder: nil, input_sources: nil)
        new(user:, title:, content:, tags:, creation_key:, plan_type:, folder:, input_sources:).call
      end

      def initialize(user:, title:, content:, tags:, creation_key:, plan_type:, folder:, input_sources:)
        @user, @title, @content, @tags, @creation_key = user, title, content, tags, creation_key
        @plan_type, @folder = plan_type, folder
        @input_sources = input_sources
      end

      def call
        if !@creation_key.nil? && (!@creation_key.is_a?(String) || !KEY_FORMAT.match?(@creation_key))
          raise InvalidKey, "Invalid draft creation key"
        end
        @creation_key = @creation_key&.downcase
        # Serialize retries for this author; the unique index also guards the
        # receipt. Never overwrite edits made since the first request committed.
        @user.with_lock do
          existing = @user.created_plans.find_by(creation_key: @creation_key) if @creation_key
          next existing if existing
          plan = Create.call(title: @title, content: @content, user: @user, plan_type_id: @plan_type&.id,
            actor_type: "human", actor_id: @user.id, creation_key: @creation_key, input_sources: @input_sources)
          plan.tag_names = @plan_type&.default_tags.to_a | @tags.to_s.split(",").map(&:strip).reject(&:blank?)
          plan.save!
          if @folder
            result = Place.call(plan: plan, folder: @folder, actor: @user)
            raise PlacementFailed, result.error unless result.success?
          end
          plan
        end
      end
    end
  end
end

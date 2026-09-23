module CoPlan
  module Plans
    class CreateHumanDraft
      class InvalidKey < StandardError; end
      KEY_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      def self.call(user:, title:, content:, tags:, creation_key: nil)
        new(user:, title:, content:, tags:, creation_key:).call
      end

      def initialize(user:, title:, content:, tags:, creation_key:)
        @user, @title, @content, @tags, @creation_key = user, title, content, tags, creation_key
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
          plan = Create.call(title: @title, content: @content, user: @user, visibility: "draft", actor_type: "human", creation_key: @creation_key)
          plan.tag_names = @tags.to_s.split(",")
          plan.save!
          plan
        end
      end
    end
  end
end

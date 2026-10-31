module CoPlan
  # A person's emoji acknowledgement of a comment. Reactions come from a
  # fixed set so they can be stored as plain string keys; KINDS is the one
  # place that maps a key to its emoji and its spoken label.
  class CommentReaction < ApplicationRecord
    KINDS = {
      "thumbs_up" => { emoji: "👍", label: "thumbs up" },
      "heart" => { emoji: "❤️", label: "heart" },
      "tada" => { emoji: "🎉", label: "party popper" },
      "eyes" => { emoji: "👀", label: "eyes" },
      "smile" => { emoji: "😄", label: "smile" },
      "rocket" => { emoji: "🚀", label: "rocket" }
    }.transform_values(&:freeze).freeze

    belongs_to :comment
    belongs_to :user, class_name: "CoPlan::User"

    validates :kind, presence: true, inclusion: { in: KINDS.keys }
    validates :kind, uniqueness: { scope: [ :comment_id, :user_id ] }

    def self.emoji_for(kind)
      KINDS.fetch(kind).fetch(:emoji)
    end

    def self.label_for(kind)
      KINDS.fetch(kind).fetch(:label)
    end

    # Groups reactions by kind in KINDS order, each group in the order
    # people reacted. Works on a preloaded collection without extra queries.
    def self.summarize(reactions)
      grouped = reactions.sort_by { |reaction| [ reaction.created_at, reaction.id ] }.group_by(&:kind)
      KINDS.keys.filter_map do |kind|
        next unless (members = grouped[kind])

        { kind: kind, emoji: emoji_for(kind), count: members.size, reactions: members }
      end
    end

    # Loads reactions and their people for the given comments in a fixed
    # number of queries. Comments that already have them loaded are skipped.
    def self.preload_for(comments)
      ActiveRecord::Associations::Preloader.new(records: Array(comments), associations: { reactions: :user }).call
    end

    # The read-only shape agents see on each comment in thread JSON.
    def self.as_api_json(comment)
      return [] if comment.deleted?

      summarize(comment.reactions).map do |entry|
        entry.slice(:kind, :emoji, :count).merge(user_ids: entry[:reactions].map(&:user_id))
      end
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id comment_id user_id kind created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[comment user]
    end
  end
end

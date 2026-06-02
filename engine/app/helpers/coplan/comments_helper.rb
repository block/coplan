module CoPlan
  module CommentsHelper
    def comment_author_name(comment)
      user = comment_author_user(comment)
      user_name = user&.name || comment.author_type

      comment.agent_name.present? ? "#{comment.agent_name} (via #{user_name})" : user_name
    end

    def comment_author_user(comment)
      @_comment_author_cache ||= {}
      cache_key = "#{comment.author_type}:#{comment.author_id}"
      @_comment_author_cache.fetch(cache_key) do
        @_comment_author_cache[cache_key] = comment.author
      end
    end
  end
end

module Coplan
  module CommentsHelper
    def comment_author_name(comment)
      user = comment_author_user(comment)
      user_name = user&.name || comment.author_type

      comment.agent_name.present? ? I18n.t("coplan.common.messages.agent_name_via_user_name", agent_name: comment.agent_name, user_name: user_name) : user_name
    end

    def comment_agent_owner_label(comment)
      owner = comment_author_user(comment)
      return I18n.t("coplan.discussions.messages.ai_agent") unless owner

      name = owner.name.to_s.split.first.presence || I18n.t("coplan.discussions.messages.user")
      I18n.t("coplan.discussions.messages.name_s_agent", name: name)
    end

    def comment_agent_icon_source(comment)
      harness = comment.agent_harness
      return asset_path("coplan/agent-avatar.svg") unless harness

      harness.icon_url.presence || asset_path(harness.built_in_icon)
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

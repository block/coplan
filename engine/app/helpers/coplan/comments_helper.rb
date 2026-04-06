module CoPlan
  module CommentsHelper
    def comment_author_name(comment)
      user = comment_author_user(comment)
      user_name = user&.name
      user_name ||= if comment.author_type == "cloud_persona"
        AutomatedPlanReviewer.find_by(id: comment.author_id)&.name || "Reviewer"
      else
        comment.author_type
      end

      comment.agent_name.present? ? "#{comment.agent_name} (via #{user_name})" : user_name
    end

    def comment_author_user(comment)
      case comment.author_type
      when "human"
        CoPlan::User.find_by(id: comment.author_id)
      when "local_agent"
        CoPlan::User
          .joins(:api_tokens)
          .where(coplan_api_tokens: { id: comment.author_id })
          .first
      else
        nil
      end
    end
  end
end

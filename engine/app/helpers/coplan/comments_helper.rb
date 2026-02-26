module CoPlan
  module CommentsHelper
    def comment_author_name(comment)
      case comment.author_type
      when "human"
        CoPlan.user_class.find_by(id: comment.author_id)&.name || "Unknown"
      when "local_agent"
        user_name = CoPlan.user_class
          .joins("INNER JOIN coplan_api_tokens ON coplan_api_tokens.user_id = users.id")
          .where("coplan_api_tokens.id = ?", comment.author_id)
          .pick(:name) || "Agent"
        comment.agent_name.present? ? "#{user_name} (#{comment.agent_name})" : user_name
      when "cloud_persona"
        AutomatedPlanReviewer.find_by(id: comment.author_id)&.name || "Reviewer"
      else
        comment.author_type
      end
    end
  end
end

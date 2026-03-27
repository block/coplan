module CoPlan
  module CommentsHelper
    def comment_author_name(comment)
      user_name = case comment.author_type
      when "human"
        CoPlan::User.find_by(id: comment.author_id)&.name || "Unknown"
      when "local_agent"
        CoPlan::User
          .joins(:api_tokens)
          .where(coplan_api_tokens: { id: comment.author_id })
          .pick(:name) || "Agent"
      when "cloud_persona"
        AutomatedPlanReviewer.find_by(id: comment.author_id)&.name || "Reviewer"
      else
        comment.author_type
      end

      comment.agent_name.present? ? "#{comment.agent_name} (via #{user_name})" : user_name
    end
  end
end

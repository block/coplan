module CommentsHelper
  def comment_author_name(comment)
    case comment.author_type
    when "human"
      User.find_by(id: comment.author_id)&.name || "Unknown"
    when "local_agent"
      user_name = User.joins(:api_tokens).where(api_tokens: { id: comment.author_id }).pick(:name) || "Agent"
      comment.agent_name.present? ? "#{user_name} (#{comment.agent_name})" : user_name
    when "cloud_persona"
      AutomatedPlanReviewer.find_by(id: comment.author_id)&.name || "Reviewer"
    else
      comment.author_type
    end
  end
end

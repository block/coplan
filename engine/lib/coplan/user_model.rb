module CoPlan
  # Concern to be included by the host app's User model.
  #
  # Required interface:
  #   #id                → String (any unique string — UUID, ULID, etc.)
  #   #name              → String (display name)
  #   #can_admin_coplan? → Boolean (can this user manage reviewers, prompts, etc.)
  #
  # The engine manages its own associations (api_tokens, plan_collaborators)
  # internally — the host app does not need to declare them.
  module UserModel
    extend ActiveSupport::Concern

    included do
      has_many :coplan_api_tokens,
               class_name: "CoPlan::ApiToken",
               foreign_key: :user_id,
               dependent: :destroy

      has_many :coplan_plan_collaborators,
               class_name: "CoPlan::PlanCollaborator",
               foreign_key: :user_id,
               dependent: :destroy
    end

    def can_admin_coplan?
      false
    end
  end
end

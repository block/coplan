class AddSummaryToCoplanPlans < ActiveRecord::Migration[8.1]
  def change
    change_table :coplan_plans do |t|
      t.text :summary
      t.datetime :summary_generated_at
      # SHA256 of the PlanVersion content the summary was generated from.
      # Used by SummarizePlanJob to debounce regeneration: if the plan's
      # current content sha hasn't changed since the last summary, the job
      # no-ops. This lets us fire the job from every PlanVersion#after_create_commit
      # without re-calling the AI on rapid back-to-back edits.
      t.string :summary_content_sha256, limit: 64
    end
  end
end

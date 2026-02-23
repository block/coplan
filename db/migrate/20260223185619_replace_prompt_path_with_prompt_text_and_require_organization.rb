class ReplacePromptPathWithPromptTextAndRequireOrganization < ActiveRecord::Migration[8.1]
  def up
    add_column :automated_plan_reviewers, :prompt_text, :text, null: true

    # Migrate existing prompt_path data to prompt_text by reading file contents
    AutomatedPlanReviewer.reset_column_information
    AutomatedPlanReviewer.find_each do |reviewer|
      file_path = Rails.root.join(reviewer.prompt_path)
      if File.exist?(file_path)
        reviewer.update_column(:prompt_text, File.read(file_path))
      end
    end

    change_column_null :automated_plan_reviewers, :prompt_text, false
    remove_column :automated_plan_reviewers, :prompt_path

    # Make organization_id required
    change_column_null :automated_plan_reviewers, :organization_id, false
  end

  def down
    add_column :automated_plan_reviewers, :prompt_path, :string, null: true
    change_column_null :automated_plan_reviewers, :organization_id, true
    remove_column :automated_plan_reviewers, :prompt_text
  end
end

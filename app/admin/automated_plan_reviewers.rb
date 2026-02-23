ActiveAdmin.register AutomatedPlanReviewer do
  permit_params :organization_id, :key, :name, :prompt_text, :enabled, :ai_provider, :ai_model, trigger_statuses: []

  index do
    selectable_column
    id_column
    column :key
    column :name
    column :organization
    column :enabled
    column :ai_provider
    column :ai_model
    column :trigger_statuses
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :key
      row :name
      row :organization
      row :prompt_text
      row :enabled
      row :ai_provider
      row :ai_model
      row :trigger_statuses
      row :created_at
      row :updated_at
    end
  end
end

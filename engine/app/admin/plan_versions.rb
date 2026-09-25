ActiveAdmin.register CoPlan::PlanVersion, as: "PlanVersion" do
  actions :index, :show

  index do
    selectable_column
    id_column
    column :plan
    column :revision
    column :actor_type
    column :content_sha256
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :plan
      row :revision
      row :actor_type
      row :actor_id
      row :content_sha256
      row :change_summary
      row :reason
      row :ai_provider
      row :ai_model
      row :base_revision
      row :created_at
    end

    panel "Content" do
      pre resource.content_markdown
    end
  end
end

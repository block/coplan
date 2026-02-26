ActiveAdmin.register CoPlan::CommentThread, as: "CommentThread" do
  permit_params :status, :out_of_date

  index do
    selectable_column
    id_column
    column :plan
    column :status
    column :start_line
    column :end_line
    column :out_of_date
    column :created_by_user
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :plan
      row :organization
      row :plan_version
      row :status
      row :start_line
      row :end_line
      row :out_of_date
      row :out_of_date_since_version
      row :addressed_in_plan_version
      row :created_by_user
      row :resolved_by_user
      row :created_at
      row :updated_at
    end

    panel "Comments" do
      table_for resource.comments.order(created_at: :asc) do
        column :id
        column :author_type
        column :author_id
        column :body_markdown
        column :created_at
      end
    end
  end
end

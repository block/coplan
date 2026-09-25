ActiveAdmin.register CoPlan::Comment, as: "PlanComment" do
  permit_params :body_markdown

  index do
    selectable_column
    id_column
    column :comment_thread
    column :author_type
    column :author_id
    column(:body_markdown) { |c| truncate(c.body_markdown, length: 80) }
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :comment_thread
      row :author_type
      row :author_id
      row :body_markdown
      row :created_at
      row :updated_at
    end
  end
end

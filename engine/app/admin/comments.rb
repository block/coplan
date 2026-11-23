ActiveAdmin.register Coplan::Comment, as: "PlanComment" do
  # No destroy and no batch delete: a hard delete leaves no trace, and
  # nothing in Coplan can restore it. Authors soft-delete their own comments.
  actions :all, except: [ :destroy ]
  config.batch_actions = false
  permit_params :body_markdown

  filter :comment_thread_id
  filter :author_type
  filter :created_at

  index do
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

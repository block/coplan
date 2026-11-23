ActiveAdmin.register CoPlan::Comment, as: "PlanComment" do
  # Inspect retained content here; permanent deletion is a separate action.
  actions :index, :show
  config.batch_actions = false

  filter :comment_thread_id
  filter :author_type
  filter :created_at
  filter :deleted_at

  member_action :permanently_delete, method: :delete do
    unless params[:confirmation] == "DELETE"
      return render json: { error: "Type DELETE to confirm permanent deletion." }, status: :unprocessable_content
    end

    CoPlan::Comments::PermanentlyDelete.call(comment: resource, actor: current_coplan_admin_user)
    render json: { html: render_to_string(partial: "coplan/admin/comment_permanently_deleted", formats: [ :html ]) }
  rescue CoPlan::Comments::PermanentlyDelete::NotAllowed => error
    render json: { error: error.message }, status: :unprocessable_content
  end

  index do
    id_column
    column :comment_thread
    column :author_type
    column :author_id
    column(:body_markdown) { |c| truncate(c.body_markdown, length: 80) }
    column :created_at
    column :deleted_at
    actions
  end

  show do
    text_node javascript_import_module_tag("coplan/admin_comments")
    div data: { controller: "coplan--admin-comment-deletion" } do
      attributes_table do
        row :id
        row :comment_thread
        row :author_type
        row :author_id
        row :body_markdown
        row :created_at
        row :updated_at
        row :deleted_at
      end
      if resource.review_note?
        para "This comment belongs to an immutable review receipt. Permanent deletion is unavailable here."
      elsif resource.deleted?
        panel "Permanently delete comment" do
          render "coplan/admin/comment_deletion", comment: resource
        end
      else
        para "This comment is active. Its author must soft-delete it before an admin can permanently delete it."
      end
    end
  end
end

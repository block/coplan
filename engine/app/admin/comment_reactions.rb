ActiveAdmin.register CoPlan::CommentReaction, as: "CommentReaction" do
  includes :comment, :user

  # Read-only: removing a reaction here would leave open pages showing it.
  # People remove their own reactions from the comment.
  actions :index, :show
  config.batch_actions = false

  filter :comment_id
  filter :user
  filter :kind, as: :select, collection: CoPlan::CommentReaction::KINDS.keys
  filter :created_at

  index do
    id_column
    column :comment
    column :user
    column(:kind) { |reaction| "#{CoPlan::CommentReaction.emoji_for(reaction.kind)} #{reaction.kind}" }
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :comment
      row :user
      row(:kind) { |reaction| "#{CoPlan::CommentReaction.emoji_for(reaction.kind)} #{reaction.kind}" }
      row :created_at
      row :updated_at
    end
  end
end

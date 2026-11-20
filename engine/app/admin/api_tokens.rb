ActiveAdmin.register CoPlan::ApiToken, as: "ApiToken" do
  # A token acts as its user, so its user must never change after minting:
  # an edit would attribute every later write to someone else. Destroy stays
  # so an operator can still remove a token.
  actions :index, :show, :destroy

  filter :name
  filter :user_id
  filter :revoked_at
  filter :created_at

  index do
    selectable_column
    id_column
    column :name
    column :user
    column :last_used_at
    column :revoked_at
    column :expires_at
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :user
      row :token_digest
      row :last_used_at
      row :revoked_at
      row :expires_at
      row :created_at
      row :updated_at
    end
  end
end

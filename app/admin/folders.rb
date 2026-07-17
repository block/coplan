ActiveAdmin.register CoPlan::Folder, as: "Folder" do
  permit_params :name, :parent_id, :library_id, :created_by_user_id

  index do
    selectable_column
    id_column
    column :name
    column("Path") { |folder| folder.path }
    column :library
    column :parent
    column :created_by_user
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row("Path") { resource.path }
      row :library
      row :parent
      row :created_by_user
      row :created_at
      row :updated_at
    end

    panel "Subfolders" do
      table_for resource.children.order(:name) do
        column :id
        column :name
        column :created_at
      end
    end

    panel "Plans" do
      table_for resource.plans.order(updated_at: :desc) do
        column :id
        column :title
        column :visibility
        column :archived_at
        column :updated_at
      end
    end
  end

  form do |f|
    f.inputs do
      f.input :name
      f.input :library_id, as: :select,
        collection: CoPlan::Library.includes(:owner).map { |l| [ "#{l.owner.try(:name) || l.owner_id} — #{l.name}", l.id ] }
      f.input :parent, collection: CoPlan::Folder.order(:name).map { |folder| [folder.path, folder.id] }
      f.input :created_by_user, collection: CoPlan::User.order(:name).map { |u| [u.name, u.id] }
    end
    f.actions
  end
end

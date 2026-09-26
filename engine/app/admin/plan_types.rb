ActiveAdmin.register CoPlan::PlanType, as: "PlanType" do
  permit_params :name, :description, :icon, :template_content

  index do
    selectable_column
    id_column
    column :name
    column :icon
    column :description
    column :created_at
    actions
  end

  form do |f|
    f.inputs do
      f.input :name
      f.input :description
      # Curated set only (CoPlan::PlansHelper::PLAN_TYPE_ICONS) — icons are
      # picked by name and rendered from built-in SVG, so nothing
      # user-supplied ever reaches the page as markup. The tint is derived
      # from the type's name automatically.
      f.input :icon, as: :select,
        collection: CoPlan::PlansHelper::PLAN_TYPE_ICONS.keys,
        include_blank: "(default document icon)"
      f.input :template_content, as: :text
    end
    f.actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :icon
      row :description
      row :default_tags
      row :template_content
      row :metadata
      row :created_at
      row :updated_at
    end
  end
end

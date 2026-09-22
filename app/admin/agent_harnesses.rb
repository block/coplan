ActiveAdmin.register CoPlan::AgentHarness, as: "AgentHarness" do
  actions :index, :show, :edit, :update
  permit_params :display_name, :icon_url

  filter :key
  filter :display_name
  filter :created_at

  index do
    selectable_column
    column :icon do |harness|
      image_tag(harness.icon_url.presence || asset_path(harness.built_in_icon), width: 28, height: 28)
    end
    column :key
    column :display_name
    column :comments do |harness|
      harness.comments.count
    end
    column :updated_at
    actions
  end

  form do |f|
    f.inputs do
      f.input :key, input_html: { readonly: true }, hint: "Detected automatically from agent metadata and cannot be changed."
      f.input :display_name
      f.input :icon_url, hint: "Optional HTTP(S) image URL. Built-in Amp and Claude icons, or the generic agent icon, are used when blank."
    end
    f.actions
  end

  show do
    attributes_table do
      row :id
      row :key
      row :display_name
      row :icon_url
      row :icon do |harness|
        image_tag(harness.icon_url.presence || asset_path(harness.built_in_icon), width: 48, height: 48)
      end
      row :created_at
      row :updated_at
    end
  end
end

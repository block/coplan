ActiveAdmin.register CoPlan::LibraryEvent, as: "LibraryEvent" do
  actions :index, :show

  index do
    selectable_column
    id_column
    column :library
    column :event_type
    column :before_value
    column :after_value
    column :actor_type
    column :actor_user
    column :created_at
    actions
  end

  filter :library
  filter :event_type, as: :select, collection: CoPlan::LibraryEvent::EVENT_TYPES
  filter :actor_type, as: :select, collection: CoPlan::LibraryEvent::ACTOR_TYPES
  filter :created_at

  show do
    attributes_table do
      row :id
      row :library
      row :event_type
      row :plan_id
      row :folder_id
      row :before_value
      row :after_value
      row :actor_type
      row :actor_user
      row :metadata
      row :created_at
    end
  end
end

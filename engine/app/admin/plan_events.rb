ActiveAdmin.register CoPlan::PlanEvent, as: "PlanEvent" do
  actions :index, :show

  index do
    selectable_column
    id_column
    column :plan
    column :event_type
    column :field
    column :before_value
    column :after_value
    column :actor_type
    column :actor_user
    column :created_at
    actions
  end

  filter :plan
  filter :event_type, as: :select, collection: CoPlan::PlanEvent::EVENT_TYPES
  filter :actor_type, as: :select, collection: CoPlan::PlanEvent::ACTOR_TYPES
  filter :created_at

  show do
    attributes_table do
      row :id
      row :plan
      row :event_type
      row :field
      row :before_value
      row :after_value
      row :actor_type
      row :actor_user
      row :metadata
      row :created_at
    end
  end
end

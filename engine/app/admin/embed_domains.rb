ActiveAdmin.register CoPlan::EmbedDomain, as: "EmbedDomain" do
  menu label: "Iframe domains"
  permit_params :hostname

  index do
    selectable_column
    column :hostname
    column :created_at
    actions
  end

  form do |f|
    f.inputs "Allowed iframe domain" do
      f.input :hostname, hint: "Exact host only, for example www.openstreetmap.org. HTTPS only. Subdomains must be approved separately."
    end
    f.actions
  end
end

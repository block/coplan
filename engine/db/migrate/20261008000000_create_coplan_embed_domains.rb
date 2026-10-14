class CreateCoplanEmbedDomains < ActiveRecord::Migration[8.0]
  def change
    create_table :coplan_embed_domains, id: :string, limit: 36 do |t|
      t.string :hostname, null: false
      t.timestamps
    end
    add_index :coplan_embed_domains, :hostname, unique: true
  end
end

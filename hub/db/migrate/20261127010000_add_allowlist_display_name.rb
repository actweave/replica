class AddAllowlistDisplayName < ActiveRecord::Migration[8.1]
  def change
    add_column :auth_allowlist_entries, :display_name, :string, limit: 80
  end
end

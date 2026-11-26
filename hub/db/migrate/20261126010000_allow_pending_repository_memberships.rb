class AllowPendingRepositoryMemberships < ActiveRecord::Migration[8.1]
  def change
    add_reference :repository_memberships, :auth_allowlist_entry, foreign_key: { on_delete: :cascade }
    change_column_null :repository_memberships, :user_id, true
    add_check_constraint :repository_memberships, "(user_id IS NULL) != (auth_allowlist_entry_id IS NULL)",
      name: "repository_memberships_one_recipient"
    add_index :repository_memberships, %i[repository_id auth_allowlist_entry_id], unique: true,
      where: "auth_allowlist_entry_id IS NOT NULL", name: "index_pending_repository_grants"
  end
end

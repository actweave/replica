class AddHubIdentitiesAndMemberships < ActiveRecord::Migration[8.1]
  def change
    remove_index :users, "(github_id IS NULL)", unique: true,
      where: "github_id IS NULL", name: "index_users_on_one_local_identity"
    add_column :users, :identity_kind, :string
    reversible do |direction|
      direction.up { execute "UPDATE users SET identity_kind = CASE WHEN github_id IS NULL THEN 'local' ELSE 'github' END" }
      direction.down do
        if select_value("SELECT 1 FROM users WHERE identity_kind = 'external' LIMIT 1")
          raise ActiveRecord::IrreversibleMigration, "External identities require the new schema"
        end
      end
    end
    change_column_null :users, :identity_kind, false
    add_check_constraint :users,
      "(identity_kind = 'github' AND github_id IS NOT NULL) OR " \
        "(identity_kind IN ('local', 'external') AND github_id IS NULL)", name: "users_identity_kind"
    add_index :users, :identity_kind, unique: true, where: "identity_kind = 'local'",
      name: "index_users_on_one_local_identity"
    add_column :users, :membership_version, :integer, null: false, default: 0
    add_column :users, :email, :string
    add_index :users, :email, unique: true, where: "email IS NOT NULL"

    create_table :user_identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :issuer
      t.string :subject, null: false
      t.string :email
      t.boolean :email_verified, null: false, default: false
      t.datetime :last_signed_in_at
      t.timestamps
      t.index [ :provider, :subject ], unique: true
    end

    create_table :auth_allowlist_entries do |t|
      t.string :email, null: false, index: { unique: true }
      t.boolean :hub_admin, null: false, default: false
      t.references :added_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :notes
      t.timestamps
    end

    # A removed entry must stay removed across restarts with the same environment.
    create_table :auth_allowlist_seeds do |t|
      t.string :email, null: false
      t.boolean :hub_admin, null: false
      t.index [ :email, :hub_admin ], unique: true
    end

    create_table :repository_memberships do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false
      t.references :granted_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
      t.index [ :repository_id, :user_id ], unique: true
      t.check_constraint "role IN ('read', 'write', 'admin')", name: "repository_memberships_role"
    end
  end
end

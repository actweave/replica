class CreateEmailLoginChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :email_login_challenges do |t|
      t.string :email, null: false
      t.string :code_digest, null: false, default: ""
      t.datetime :expires_at, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :consumed_at
      t.string :request_ip
      t.timestamps
    end
    add_index :email_login_challenges, [ :email, :created_at ]
    add_index :email_login_challenges, :expires_at
    add_index :email_login_challenges, :email, unique: true, where: "consumed_at IS NULL"
  end
end

class TrackSelfHostedBuildClaims < ActiveRecord::Migration[8.1]
  def change
    add_column :builds, :self_hosted, :boolean, null: false, default: false
  end
end

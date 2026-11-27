class AllowExternalCommentMentions < ActiveRecord::Migration[8.1]
  def change
    add_reference :comment_mentions, :external_user, foreign_key: { to_table: :users }
    change_column_null :comment_mentions, :github_identity_id, true
    add_index :comment_mentions, %i[review_comment_id external_user_id], unique: true
    add_check_constraint :comment_mentions, "(external_user_id IS NULL) != (github_identity_id IS NULL)",
      name: "comment_mentions_one_recipient"
    change_column_null :notifications, :recipient_id, true
    add_check_constraint :notifications, "recipient_id IS NOT NULL OR kind = 'comment_mention'",
      name: "notifications_recipient_or_mention"
  end
end

Rails.application.config.after_initialize do
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?
  next if ENV["REPLICA_AUTH_ALLOWLIST_EMAILS"].blank? && ENV["REPLICA_AUTH_BOOTSTRAP_ADMIN_EMAILS"].blank?

  AuthAllowlistEntry.bootstrap! if AuthAllowlistSeed.table_exists?
end

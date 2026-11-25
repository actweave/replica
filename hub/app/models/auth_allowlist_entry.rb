# == Schema Information
#
# Table name: auth_allowlist_entries
# Database name: primary
#
#  id          :integer          not null, primary key
#  email       :string           not null
#  hub_admin   :boolean          default(FALSE), not null
#  notes       :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  added_by_id :integer
#
# Indexes
#
#  index_auth_allowlist_entries_on_added_by_id  (added_by_id)
#  index_auth_allowlist_entries_on_email        (email) UNIQUE
#
# Foreign Keys
#
#  added_by_id  (added_by_id => users.id) ON DELETE => nullify
#
# Admits verified email addresses and records their initial Hub role.
class AuthAllowlistEntry < ApplicationRecord
  belongs_to :added_by, class_name: "User", optional: true

  normalizes :email, with: -> { _1.strip.downcase.presence }
  validates :email, presence: true, uniqueness: true, format: URI::MailTo::EMAIL_REGEXP

  # Applies each configured grant once. Later database edits survive restarts.
  def self.bootstrap!(env = ENV)
    transaction do
      [ [ "REPLICA_AUTH_ALLOWLIST_EMAILS", false ], [ "REPLICA_AUTH_BOOTSTRAP_ADMIN_EMAILS", true ] ].each do |key, admin|
        env[key].to_s.split(",").map { normalize_value_for(:email, _1) }.compact.uniq.each do |email|
          receipt = AuthAllowlistSeed.find_or_create_by!(email:, hub_admin: admin)
          next unless receipt.previously_new_record?

          entry = find_or_initialize_by(email:)
          entry.hub_admin = true if admin
          entry.save!
        end
      end
    end
  end
end

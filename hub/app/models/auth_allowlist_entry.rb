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

  has_many :pending_memberships, class_name: "RepositoryMembership", dependent: :delete_all

  normalizes :email, with: -> { _1.strip.downcase.presence }
  validates :email, presence: true, uniqueness: true, format: URI::MailTo::EMAIL_REGEXP

  # Bind verified mailbox ownership to a stable account with a public, non-email login.
  def admit_verified_email!(provider: "email", subject: email, issuer: nil)
    identity = UserIdentity.find_or_initialize_by(provider:, subject:)
    if identity.persisted?
      return unless identity.issuer == issuer && identity.user.email == email
    end
    user = identity.user || User.find_or_initialize_by(email:)
    return unless user.new_record? || user.external?

    if user.new_record?
      user.identity_kind = "external"
      user.login = "reviewer-#{SecureRandom.hex(8)}"
    end
    user.hub_admin = true if hub_admin?
    user.update!(last_authenticated_at: Time.current)
    pending_memberships.each { _1.update!(user:, auth_allowlist_entry: nil) }
    identity.update!(user:, issuer:, email:, email_verified: true, last_signed_in_at: user.last_authenticated_at)
    user
  end

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

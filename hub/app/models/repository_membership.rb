# == Schema Information
#
# Table name: repository_memberships
# Database name: primary
#
#  id                      :integer          not null, primary key
#  role                    :string           not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  auth_allowlist_entry_id :integer
#  granted_by_id           :integer
#  repository_id           :integer          not null
#  user_id                 :integer
#
# Indexes
#
#  index_pending_repository_grants                            (repository_id,auth_allowlist_entry_id) UNIQUE WHERE auth_allowlist_entry_id IS NOT NULL
#  index_repository_memberships_on_auth_allowlist_entry_id    (auth_allowlist_entry_id)
#  index_repository_memberships_on_granted_by_id              (granted_by_id)
#  index_repository_memberships_on_repository_id              (repository_id)
#  index_repository_memberships_on_repository_id_and_user_id  (repository_id,user_id) UNIQUE
#  index_repository_memberships_on_user_id                    (user_id)
#
# Foreign Keys
#
#  auth_allowlist_entry_id  (auth_allowlist_entry_id => auth_allowlist_entries.id) ON DELETE => cascade
#  granted_by_id            (granted_by_id => users.id) ON DELETE => nullify
#  repository_id            (repository_id => repositories.id)
#  user_id                  (user_id => users.id)
#
# Check Constraints
#
#  repository_memberships_one_recipient  ((user_id IS NULL) != (auth_allowlist_entry_id IS NULL))
#  repository_memberships_role           (role IN ('read', 'write', 'admin'))
#
# Grants one Hub account a role in a single repository.
class RepositoryMembership < ApplicationRecord
  belongs_to :repository
  belongs_to :user, optional: true
  belongs_to :auth_allowlist_entry, optional: true
  belongs_to :granted_by, class_name: "User", optional: true
  attr_readonly :repository_id

  validates :role, inclusion: { in: %w[read write admin] }
  validates :user_id, uniqueness: { scope: :repository_id }, allow_nil: true
  validates :auth_allowlist_entry_id, uniqueness: { scope: :repository_id }, allow_nil: true
  validate do
    errors.add(:base, :invalid) if user.present? == auth_allowlist_entry.present?
    errors.add(:user_id, :invalid) if user_id_in_database && will_save_change_to_user_id?
  end

  after_save :advance_version, if: :user_id
  after_destroy :advance_version, :revoke_external_shares, if: :user_id

  def audit_context
    user_id ? { target_user_id: user_id } : { allowlist_entry_id: auth_allowlist_entry_id }
  end

  private

  def advance_version
    User.increment_counter(:membership_version, user_id)
  end

  # External creators lose their public links in the same transaction as access.
  def revoke_external_shares
    ShareLinkCreatorRevocation.confirm_loss!(repository:, user:) if user.external?
  end
end

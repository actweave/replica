# == Schema Information
#
# Table name: repository_memberships
# Database name: primary
#
#  id            :integer          not null, primary key
#  role          :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  granted_by_id :integer
#  repository_id :integer          not null
#  user_id       :integer          not null
#
# Indexes
#
#  index_repository_memberships_on_granted_by_id              (granted_by_id)
#  index_repository_memberships_on_repository_id              (repository_id)
#  index_repository_memberships_on_repository_id_and_user_id  (repository_id,user_id) UNIQUE
#  index_repository_memberships_on_user_id                    (user_id)
#
# Foreign Keys
#
#  granted_by_id  (granted_by_id => users.id) ON DELETE => nullify
#  repository_id  (repository_id => repositories.id)
#  user_id        (user_id => users.id)
#
# Check Constraints
#
#  repository_memberships_role  (role IN ('read', 'write', 'admin'))
#
# Grants one Hub account a role in a single repository.
class RepositoryMembership < ApplicationRecord
  belongs_to :repository
  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true
  attr_readonly :repository_id, :user_id

  validates :role, inclusion: { in: %w[read write admin] }
  validates :user_id, uniqueness: { scope: :repository_id }

  after_save :advance_version
  after_destroy :advance_version, :revoke_external_shares

  private

  def advance_version
    User.increment_counter(:membership_version, user_id)
  end

  # External creators lose their public links in the same transaction as access.
  def revoke_external_shares
    ShareLinkCreatorRevocation.confirm_loss!(repository:, user:) if user.external?
  end
end

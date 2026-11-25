# == Schema Information
#
# Table name: user_identities
# Database name: primary
#
#  id                :integer          not null, primary key
#  email             :string
#  email_verified    :boolean          default(FALSE), not null
#  issuer            :string
#  last_signed_in_at :datetime
#  provider          :string           not null
#  subject           :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :integer          not null
#
# Indexes
#
#  index_user_identities_on_provider_and_subject  (provider,subject) UNIQUE
#  index_user_identities_on_user_id               (user_id)
#
# Foreign Keys
#
#  user_id  (user_id => users.id)
#
# Binds a provider's stable subject to one Hub account.
class UserIdentity < ApplicationRecord
  belongs_to :user
  normalizes :email, with: -> { _1.strip.downcase.presence }
  before_validation { self.subject = subject&.strip&.downcase if provider == "email" }
  validates :provider, :subject, presence: true
  validates :subject, uniqueness: { scope: :provider }
end

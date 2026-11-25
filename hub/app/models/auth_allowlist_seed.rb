# == Schema Information
#
# Table name: auth_allowlist_seeds
# Database name: primary
#
#  id        :integer          not null, primary key
#  email     :string           not null
#  hub_admin :boolean          not null
#
# Indexes
#
#  index_auth_allowlist_seeds_on_email_and_hub_admin  (email,hub_admin) UNIQUE
#
# Remembers applied environment grants independently of the editable allowlist.
class AuthAllowlistSeed < ApplicationRecord
end
